// SwitchMTP — a macOS MTP client for Nintendo Switch running DBI.
// Copyright (C) 2024 Neighbor_Z
// Copyright (C) 2025 fratei
//
// This program is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License version 2 as published by
// the Free Software Foundation.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
// more details.

import Foundation
import Dispatch
import Darwin

private enum ExitCode: Int32 {
    case success = 0
    case failure = 1
    case usage = 2
    case deviceNotFound = 3
    case cancelled = 4
    case deviceBusy = 5
    case unsupported = 6
}

private struct CLIError: Error {
    let message: String
    let code: ExitCode
}

private struct Config {
    var verbose = false
    var json = false
    var quiet = false
    var assumeYes = false
    var deviceId: String?
    var keysPath: String?
}

/// Version shown by the `version` command. When the CLI is embedded in the
/// app bundle the host Info.plist supplies the shipped version; a standalone
/// debug build has no plist and reports `dev`.
private var cliVersion: String {
    if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
       !v.isEmpty {
        return v
    }
    // Embedded as a nested executable: walk up from the binary to the host
    // bundle's Contents/Info.plist (e.g. Contents/Resources/bin/ -> Contents/).
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    var dir = exe.deletingLastPathComponent()
    for _ in 0..<5 {
        let plist = dir.appendingPathComponent("Contents/Info.plist")
        if let dict = NSDictionary(contentsOf: plist),
           let v = dict["CFBundleShortVersionString"] as? String, !v.isEmpty {
            return v
        }
        dir = dir.deletingLastPathComponent()
    }
    return "dev"
}

/// Host CPU architecture, reported by `version` so machine-readable output can
/// tell arm64 from x86_64.
private var hostArch: String {
    var uts = utsname()
    uname(&uts)
    return withUnsafePointer(to: &uts.machine) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
    }
}

private struct RemotePath {
    /// Raw storage selector from the argument: a numeric sid, a kind alias
    /// ("sdcard", "saves", …), a display name, or a unique display-name prefix.
    let selector: String
    let path: String
    /// Resolved only when the selector is a numeric sid. Named selectors are
    /// resolved against the connected device's storage list inside the open
    /// session.
    var storageId: UInt32?
}

/// Maps CLI storage aliases onto backend storage kinds. Kept in step with the
/// upstream Go selector table; the right-hand values match `nxmtp.StorageKind`.
private let storageAliases: [String: String] = [
    "sdcard": "sdCard", "sd": "sdCard", "microsd": "sdCard",
    "nand": "nandUser", "nanduser": "nandUser", "user": "nandUser",
    "nandsystem": "nandSystem", "system": "nandSystem",
    "games": "installedGames", "installedgames": "installedGames",
    "sdinstall": "sdInstall", "installsd": "sdInstall",
    "nandinstall": "nandInstall", "installnand": "nandInstall",
    "saves": "saves", "save": "saves",
    "album": "album", "screenshots": "album",
    "gamecard": "gamecard", "cartridge": "gamecard",
]

/// Copy direction. `nil` lets `cp` infer it from which side carries a device
/// path; `get`/`put` pin it explicitly.
private enum CopyDirection {
    case download
    case upload
}

private final class CallbackState {
    static let shared = CallbackState()
    private let lock = NSLock()
    var doneJSON: String?
    var printedProgress = false

    func setDone(_ json: String?) {
        lock.lock()
        doneJSON = json
        lock.unlock()
    }

    func reset() {
        lock.lock()
        doneJSON = nil
        printedProgress = false
        lock.unlock()
    }

    func markProgressPrinted() {
        lock.lock()
        printedProgress = true
        lock.unlock()
    }

    func consumeProgressPrinted() -> Bool {
        lock.lock()
        let value = printedProgress
        printedProgress = false
        lock.unlock()
        return value
    }
}

private let cbDone: @convention(c) (UnsafeMutablePointer<CChar>?) -> Void = { ptr in
    if CallbackState.shared.consumeProgressPrinted() {
        print("\r\u{001B}[K", terminator: "")
        fflush(stdout)
    }
    CallbackState.shared.setDone(ptr.map { String(cString: $0) })
}

private let cbPreprocess: @convention(c) (UnsafeMutablePointer<CChar>?) -> Void = { ptr in
    guard !Runtime.shared.config.json, !Runtime.shared.config.quiet, let ptr else { return }
    let env = Envelope(json: String(cString: ptr))
    guard env.isSuccess, let data = env.data as? [String: Any] else { return }
    let files = int64(data["totalFiles"]) ?? 0
    let dirs = int64(data["totalDirectories"]) ?? 0
    let total = int64(data["totalSize"]) ?? 0
    let unknown = bool(data["sizeUnknown"]) ?? false
    let size = unknown ? "unknown size" : formatBytes(UInt64(max(total, 0)))
    print("Preparing transfer: \(files) file(s), \(dirs) director(y/ies), \(size)")
}

private let cbProgress: @convention(c) (UnsafeMutablePointer<CChar>?) -> Void = { ptr in
    guard !Runtime.shared.config.json, !Runtime.shared.config.quiet, let ptr else { return }
    let env = Envelope(json: String(cString: ptr))
    guard env.isSuccess, let data = env.data as? [String: Any] else { return }

    let status = string(data["status"]) ?? "transferring"
    let name = string(data["name"]) ?? ""
    let note = string(data["note"]) ?? ""
    let speed = double(data["speed"]) ?? 0
    let speedText = speed > 0 ? "\(formatBytes(UInt64(max(speed, 0))))/s" : "—"
    let bulk = data["bulkFileSize"] as? [String: Any]
    let percent = double(bulk?["progress"] ?? 0) ?? 0
    let indefinite = bool(data["indefinite"]) ?? false
    let totalFiles = int64(data["totalFiles"]) ?? 0
    var filesSent = int64(data["filesSent"]) ?? 0
    let currentFile = int64(data["currentFile"]) ?? 0
    if totalFiles > 1 {
        if currentFile > 0 { filesSent = currentFile }
        else if filesSent == 0 { filesSent += 1 }
        if filesSent > totalFiles { filesSent = totalFiles }
    }

    let progressText: String
    var etaText = ""
    if indefinite {
        // While DBI commits an install the byte count is already at 100% but
        // the console is still working; show the note instead of a full bar.
        progressText = note.isEmpty ? "working…" : note
    } else {
        progressText = String(format: "%5.1f%%", percent)
        if speed > 0, let bulkTotal = int64(bulk?["total"]),
           let bulkSent = int64(bulk?["sent"]), bulkTotal > bulkSent {
            let eta = Double(bulkTotal - bulkSent) / speed
            if eta >= 1 { etaText = "  ETA \(humanDuration(eta))" }
        }
    }

    var line = "\r\(status) \(progressText) \(speedText)"
    if totalFiles > 1 { line += " [\(filesSent)/\(totalFiles)]" }
    if !name.isEmpty { line += " \(name)" }
    line += etaText
    print(line, terminator: "")
    fflush(stdout)
    CallbackState.shared.markProgressPrinted()
}

private struct Envelope {
    let raw: String
    let object: [String: Any]

    init(json: String) {
        raw = json
        if let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = dict
        } else {
            object = ["errorType": "internal", "error": "Invalid JSON returned by backend", "data": NSNull()]
        }
    }

    var errorType: String { string(object["errorType"]) ?? "internal" }
    var error: String { string(object["error"]) ?? "" }
    var hint: String? { string(object["hint"]) }
    var data: Any? { object["data"] }
    var isSuccess: Bool { errorType.isEmpty }
}

private final class Runtime {
    static let shared = Runtime()
    var config = Config()
}

/// Installs SIGINT/SIGTERM dispatch sources for the open session. The first
/// signal cancels the in-flight transfer cleanly; a second forces an immediate
/// exit (code 4). `CancelTransfer` is the one backend call designed to run from
/// another thread mid-operation, so it is safe to invoke from the source queue.
///
/// Note: do NOT call `signal(sig, SIG_IGN)` before creating the source. A
/// SIG_IGN disposition makes the kernel drop the signal before the dispatch
/// source can observe it, so the handler never fires (verified on hardware,
/// with and without the Go backend dylib loaded).
private final class SignalGuard {
    static let shared = SignalGuard()
    private var sources: [DispatchSourceSignal] = []
    private var deviceId: String?
    private var signalCount = 0
    private let lock = NSLock()

    func arm(deviceId: String) {
        lock.lock(); defer { lock.unlock() }
        self.deviceId = deviceId
        signalCount = 0
        for sig in [SIGINT, SIGTERM] {
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler { [weak self] in self?.handle() }
            src.resume()
            sources.append(src)
        }
    }

    func disarm() {
        lock.lock(); defer { lock.unlock() }
        for src in sources { src.cancel() }
        sources.removeAll()
        deviceId = nil
    }

    private func handle() {
        lock.lock()
        signalCount += 1
        let count = signalCount
        let id = deviceId
        lock.unlock()

        if count >= 2 {
            fputs("\nForced quit.\n", stderr)
            exit(ExitCode.cancelled.rawValue)
        }
        if !Runtime.shared.config.json && !Runtime.shared.config.quiet {
            fputs("\nCancelling… (press Ctrl-C again to force quit)\n", stderr)
        }
        if let id = id { NxmtpClient.cancel(deviceId: id) }
    }
}

private enum NxmtpClient {
    static func fetchDevices() -> Envelope {
        CallbackState.shared.reset()
        NxmtpFetchAvailableDevices(cbDone)
        return result()
    }

    static func fetchDiagnostics() -> Envelope {
        CallbackState.shared.reset()
        NxmtpFetchDiagnostics(cbDone)
        return result()
    }

    static func setVerbose(_ enabled: Bool) {
        NxmtpSetVerboseLogging(enabled ? 1 : 0)
    }

    static func initialize(deviceId: String) -> Envelope {
        callWithDevice(NxmtpInitialize, deviceId: deviceId)
    }

    static func fetchDeviceInfo(deviceId: String) -> Envelope {
        callWithDevice(NxmtpFetchDeviceInfo, deviceId: deviceId)
    }

    static func fetchStorages(deviceId: String) -> Envelope {
        callWithDevice(NxmtpFetchStorages, deviceId: deviceId)
    }

    static func dispose(deviceId: String) -> Envelope {
        callWithDevice(NxmtpDispose, deviceId: deviceId)
    }

    static func walk(deviceId: String, storageId: UInt32, path: String, recursive: Bool = false, skipHidden: Bool = true) -> Envelope {
        call(NxmtpWalk, input: [
            "deviceId": deviceId,
            "storageId": storageId,
            "fullPath": normalizedRemotePath(path),
            "recursive": recursive,
            "skipDisallowedFiles": false,
            "skipHiddenFiles": skipHidden
        ])
    }

    static func makeDirectory(deviceId: String, storageId: UInt32, path: String) -> Envelope {
        call(NxmtpMakeDirectory, input: ["deviceId": deviceId, "storageId": storageId, "fullPath": normalizedRemotePath(path)])
    }

    static func delete(deviceId: String, storageId: UInt32, paths: [String]) -> Envelope {
        call(NxmtpDeleteFile, input: ["deviceId": deviceId, "storageId": storageId, "files": paths.map(normalizedRemotePath)])
    }

    static func rename(deviceId: String, storageId: UInt32, path: String, newFileName: String) -> Envelope {
        call(NxmtpRenameFile, input: [
            "deviceId": deviceId,
            "storageId": storageId,
            "fullPath": normalizedRemotePath(path),
            "newFileName": newFileName
        ])
    }

    static func download(deviceId: String, storageId: UInt32, sources: [String], destination: String) -> Envelope {
        transfer {
            let input: [String: Any] = [
                "deviceId": deviceId,
                "storageId": storageId,
                "sources": sources.map(normalizedRemotePath),
                "destination": NSString(string: destination).expandingTildeInPath,
                "preprocessFiles": true
            ]
            return callTransfer(NxmtpDownloadFiles, input: input)
        }
    }

    static func upload(deviceId: String, storageId: UInt32, sources: [String], destination: String) -> Envelope {
        transfer {
            let input: [String: Any] = [
                "deviceId": deviceId,
                "storageId": storageId,
                "sources": sources.map { NSString(string: $0).expandingTildeInPath },
                "destination": normalizedRemotePath(destination),
                "preprocessFiles": true
            ]
            return callTransfer(NxmtpUploadFiles, input: input)
        }
    }

    static func cancel(deviceId: String) {
        _ = callWithDevice(NxmtpCancelTransfer, deviceId: deviceId)
    }

    private static func callWithDevice(_ fn: (UnsafePointer<CChar>?, NxmtpOnCbResult?) -> Void, deviceId: String) -> Envelope {
        call(fn, input: ["deviceId": deviceId])
    }

    private static func call(_ fn: (UnsafePointer<CChar>?, NxmtpOnCbResult?) -> Void, input: [String: Any]) -> Envelope {
        CallbackState.shared.reset()
        guard let json = jsonString(input) else {
            return Envelope(json: #"{"errorType":"invalidInput","error":"Failed to encode input JSON","data":null}"#)
        }
        json.withCString { fn($0, cbDone) }
        return result()
    }

    private static func callTransfer(_ fn: (UnsafePointer<CChar>?, NxmtpOnCbResult?, NxmtpOnCbResult?, NxmtpOnCbResult?) -> Void, input: [String: Any]) -> Envelope {
        CallbackState.shared.reset()
        guard let json = jsonString(input) else {
            return Envelope(json: #"{"errorType":"invalidInput","error":"Failed to encode input JSON","data":null}"#)
        }
        json.withCString { fn($0, cbPreprocess, cbProgress, cbDone) }
        return result()
    }

    private static func transfer(_ body: () -> Envelope) -> Envelope {
        // Cancellation is handled by SignalGuard's dispatch sources: the first
        // signal cancels the in-flight transfer, the second forces exit. The FFI
        // runs synchronously on the calling thread; the source dispatches its
        // handler on its own global queue, so it is not blocked by this call.
        body()
    }

    private static func result() -> Envelope {
        Envelope(json: CallbackState.shared.doneJSON ?? #"{"errorType":"internal","error":"Backend callback did not return a result","data":null}"#)
    }
}

private func printUsage() {
    print("""
    switchmtp-batch-cli - command-line access to SwitchMTP's DBI MTP backend

    Usage:
      switchmtp-batch-cli [--verbose] [--json] [--device <id>] <command> [arguments]

    Commands:
      version                         Show the CLI version and exit
      devices                         List connected MTP devices
      info                            Show selected device profile and capabilities
      storages                        List storages, kinds and capabilities
      ls [-a] [-R] <storage>:<path>   List a directory (-R recursive, -a hidden)
      cp <src>... <dst>               Copy local<->device; device paths are <storage>:<path>
      get/download <device>:<path>... <local-dir>
                                      Download one or more files from the console
      put/upload <local-file>... <device>:<path>
                                      Upload one or more local files to the console
      rm <storage>:<path>...          Delete one or more device files or folders
      mv <storage>:<path> <new-name>  Rename within the same device directory
      mkdir <storage>:<path>          Create a device directory
      install <file...> [--sd|--nand] Upload NSP/NSZ/XCI/XCZ to DBI install storage
                                      (single titles; use `batch install` for a folder/plan)
      batch scan <path...> [--keys <prod.keys>]
                                      Recursively scan files/folders, group base/update/DLC,
                                      run structural check (and signature/hash deep check
                                      with --keys). Local only; no console connection.
      batch install <path...> [--sd|--nand] [--keys <prod.keys>]
                                      Scan, review, then upload in plan order (base,
                                      update, add-ons) to the DBI install storage.
      backup-saves <dir>              Download the Saves storage to a dated folder
      restore-saves <folder>          Upload a backed-up saves folder to the Saves storage
      export-album <dir>              Download the Album (screenshots/clips) to a dated folder
      dump-gamecard <dir>             Dump the inserted gamecard to a dated folder
      doctor                          Diagnose USB/MTP connection problems

    Device paths are <storage>:<path>. <storage> may be a numeric storage id, a
    kind alias (sdcard, nand, saves, album, gamecard, …), a display name, or a
    unique prefix of the display name.

    Global flags:
      --device <id>    Select a device when more than one is connected
      --keys <path>    prod.keys for signature/hash verification (optional)
      --json           Print machine-readable JSON for the main operation
      --quiet, -q      Suppress progress and confirmation output
      --yes, -y        Skip confirmation prompts (accepted for scripting parity)
      --verbose        Enable backend protocol logging on stderr
      -h, --help       Show this help
      -V, --version    Show the CLI version
    """)
}

private func parseArguments(_ arguments: [String]) throws -> (Config, String, [String]) {
    var config = Config()
    var rest: [String] = []
    var i = 1
    while i < arguments.count {
        let arg = arguments[i]
        if arg == "--" {
            // Everything after a literal "--" is positional, so files whose
            // names begin with a dash stay reachable.
            rest.append(contentsOf: arguments[(i + 1)...])
            break
        }
        switch arg {
        case "--verbose":
            config.verbose = true
        case "--json":
            config.json = true
        case "--quiet", "-q":
            config.quiet = true
        case "--yes", "-y":
            config.assumeYes = true
        case "--device":
            i += 1
            guard i < arguments.count else { throw CLIError(message: "--device requires an id", code: .usage) }
            config.deviceId = arguments[i]
        case "--keys":
            i += 1
            guard i < arguments.count else { throw CLIError(message: "--keys requires a prod.keys path", code: .usage) }
            config.keysPath = arguments[i]
        case "--version", "-V":
            rest.append("version")
        default:
            rest.append(arg)
        }
        i += 1
    }
    guard let command = rest.first else { return (config, "help", []) }
    return (config, command, Array(rest.dropFirst()))
}

private func run() -> ExitCode {
    do {
        let (config, command, args) = try parseArguments(CommandLine.arguments)
        Runtime.shared.config = config
        if config.verbose { NxmtpClient.setVerbose(true) }

        switch command {
        case "-h", "--help", "help":
            printUsage()
            return .success
        case "version", "--version", "-V":
            if config.json {
                let info: [String: Any] = [
                    "version": cliVersion,
                    "os": ProcessInfo.processInfo.operatingSystemVersionString,
                    "arch": hostArch
                ]
                print(jsonString(info) ?? "{\"version\":\"\(cliVersion)\"}")
            } else {
                print("switchmtp-batch-cli \(cliVersion) (\(hostArch))")
            }
            return .success
        case "devices":
            return handleDevices(args: args, config: config)
        case "doctor":
            return handleDoctor(args: args, config: config)
        case "info":
            guard args.isEmpty else { throw CLIError(message: "info takes no arguments", code: .usage) }
            let deviceId = try selectedDevice(config: config)
            return withOpenDevice(deviceId: deviceId, config: config) { details in
                if config.json { print(details.raw); return .success }
                printDeviceInfo(details)
                return .success
            }
        case "storages":
            guard args.isEmpty else { throw CLIError(message: "storages takes no arguments", code: .usage) }
            let deviceId = try selectedDevice(config: config)
            return withOpenDevice(deviceId: deviceId, config: config) { _ in
                let env = NxmtpClient.fetchStorages(deviceId: deviceId)
                if config.json { print(env.raw) }
                if !env.isSuccess { printError(env); return exitCode(for: env) }
                if !config.json { printStorages(env) }
                return .success
            }
        case "ls":
            return try handleLs(args: args, config: config)
        case "cp":
            return try handleCopy(args: args, config: config, direction: nil)
        case "get", "download":
            return try handleCopy(args: args, config: config, direction: .download)
        case "put", "upload":
            return try handleCopy(args: args, config: config, direction: .upload)
        case "rm":
            return try handleRm(args: args, config: config)
        case "mv":
            return try handleMv(args: args, config: config)
        case "mkdir":
            return try handleMkdir(args: args, config: config)
        case "install":
            return try handleInstall(args: args, config: config)
        case "batch":
            return try handleBatch(args: args, config: config)
        case "backup-saves":
            return try handleBackupSaves(args: args, config: config)
        case "restore-saves":
            return try handleRestoreSaves(args: args, config: config)
        case "export-album":
            return try handleExportAlbum(args: args, config: config)
        case "dump-gamecard":
            return try handleDumpGamecard(args: args, config: config)
        default:
            throw CLIError(message: "Unknown command: \(command)", code: .usage)
        }
    } catch let error as CLIError {
        if error.code == .usage { printUsage() }
        if !error.message.isEmpty { fputs("Error: \(error.message)\n", stderr) }
        return error.code
    } catch {
        fputs("Error: \(error.localizedDescription)\n", stderr)
        return .failure
    }
}

private func handleDevices(args: [String], config: Config) -> ExitCode {
    guard args.isEmpty else {
        fputs("Error: devices takes no arguments\n", stderr)
        return .usage
    }
    let env = NxmtpClient.fetchDevices()
    if config.json { print(env.raw) }
    if !env.isSuccess { printError(env); return exitCode(for: env) }
    guard !config.json else { return .success }
    let devices = devices(from: env)
    guard !devices.isEmpty else {
        if config.json { print("[]") } else { print("No Nintendo devices found. Run `doctor` to find out why.") }
        return .success
    }
    print("Device ID                         Profile     Usable  Name")
    for device in devices {
        let id = deviceId(device)
        let profile = string(device["profile"]) ?? "unknown"
        let usable = (bool(device["usable"]) ?? true) ? "yes" : "no"
        let name = string(device["displayName"]) ?? [string(device["manufacturer"]), string(device["model"])].compactMap { $0 }.joined(separator: " ")
        print("\(id.padding(toLength: 33, withPad: " ", startingAt: 0)) \(profile.padding(toLength: 11, withPad: " ", startingAt: 0)) \(usable.padding(toLength: 6, withPad: " ", startingAt: 0)) \(name)")
        if let advice = string(device["advice"]), !advice.isEmpty { print("  Hint: \(advice)") }
    }
    return .success
}

private func handleDoctor(args: [String], config: Config) -> ExitCode {
    guard args.isEmpty else {
        fputs("Error: doctor takes no arguments\n", stderr)
        return .usage
    }
    let env = NxmtpClient.fetchDiagnostics()
    if config.json { print(env.raw) }
    if !env.isSuccess { printError(env); return exitCode(for: env) }
    guard !config.json else { return .success }
    guard let data = env.data as? [String: Any] else { return .failure }
    print("SwitchMTP Doctor")
    print("================")
    print("Verdict: \(string(data["summary"]) ?? "No diagnostic summary returned.")")
    print("System: \(string(data["platform"]) ?? "unknown")/\(string(data["arch"]) ?? "unknown")")
    print("Nintendo USB device seen: \((bool(data["nintendoSeen"]) ?? false) ? "yes" : "no")")

    let mtpDevices = data["mtpDevices"] as? [[String: Any]] ?? []
    print("MTP devices: \(mtpDevices.count)")
    for device in mtpDevices {
        print("  - \(deviceId(device)) \(string(device["displayName"]) ?? string(device["model"]) ?? "MTP device")")
        if let advice = string(device["advice"]), !advice.isEmpty { print("    Hint: \(advice)") }
    }

    let blockers = data["blockers"] as? [[String: Any]] ?? []
    if !blockers.isEmpty {
        print("Processes holding USB devices:")
        for blocker in blockers {
            let pid = int64(blocker["pid"]) ?? 0
            let name = string(blocker["name"]) ?? "process"
            print("  - \(name) (pid \(pid))")
            if let advice = string(blocker["advice"]), !advice.isEmpty { print("    Hint: \(advice)") }
        }
    }

    let advice = data["advice"] as? [String] ?? []
    print("Remediation steps:")
    if advice.isEmpty {
        print("  1. No specific issue detected. If transfer still fails, reconnect the Switch and run DBI's MTP responder again.")
    } else {
        for (index, item) in advice.enumerated() { print("  \(index + 1). \(item)") }
    }
    return .success
}

private func handleLs(args: [String], config: Config) throws -> ExitCode {
    var showAll = false
    var recursive = false
    var rest = args
    while let head = rest.first, head == "-a" || head == "--all" || head == "-R" || head == "--recursive" {
        if head == "-a" || head == "--all" { showAll = true } else { recursive = true }
        rest.removeFirst()
    }
    guard rest.count == 1, let remote = parseRemote(rest[0]) else {
        throw CLIError(message: "ls expects [-a] [-R] <storage>:<path>", code: .usage)
    }
    let deviceId = try selectedDevice(config: config)
    return withOpenDevice(deviceId: deviceId, config: config) { _ in
        let lookup = resolveRemoteStorage(remote, deviceId: deviceId, config: config)
        guard case .ready(let sid, _) = lookup else {
            if case .failed(let code) = lookup { return code }
            return .deviceNotFound
        }
        let env = NxmtpClient.walk(deviceId: deviceId, storageId: sid, path: remote.path, recursive: recursive, skipHidden: !showAll)
        if config.json { print(env.raw) }
        if !env.isSuccess { printError(env); return exitCode(for: env) }
        if !config.json { printListing(env, showAll: showAll, recursive: recursive) }
        return .success
    }
}

private func handleCopy(args: [String], config: Config, direction: CopyDirection?) throws -> ExitCode {
    guard args.count >= 2 else {
        throw CLIError(message: "copy expects one or more sources and a destination", code: .usage)
    }
    let destArg = args.last!
    let srcArgs = Array(args.dropLast())
    let destRemote = parseRemote(destArg)
    let parsedSources = srcArgs.map { ($0, parseRemote($0)) }
    let srcRemotes = parsedSources.compactMap { $0.1 }
    let srcLocals = parsedSources.filter { $0.1 == nil }.map { $0.0 }

    // Resolve the direction: explicit for get/put, inferred for `cp`.
    let dir: CopyDirection
    switch direction {
    case .download: dir = .download
    case .upload: dir = .upload
    case nil:
        if destRemote != nil && srcRemotes.count == srcArgs.count {
            dir = .upload
        } else if destRemote == nil && srcRemotes.count == srcArgs.count {
            dir = .download
        } else {
            throw CLIError(message: "cp requires one device path side: sources and destination must split into local vs <storage>:<path>", code: .usage)
        }
    }

    switch dir {
    case .download:
        guard destRemote == nil else {
            throw CLIError(message: "get: the last argument must be a local destination folder", code: .usage)
        }
        guard !srcRemotes.isEmpty else {
            throw CLIError(message: "get: sources must be device paths of the form <storage>:<path>", code: .usage)
        }
        let selector = srcRemotes[0].selector
        guard srcRemotes.allSatisfy({ $0.selector == selector }) else {
            throw CLIError(message: "get: all sources must be on the same storage", code: .usage)
        }
    case .upload:
        guard let destRemote else {
            throw CLIError(message: "put: the last argument must be a device path of the form <storage>:<path>", code: .usage)
        }
        guard srcLocals.count == srcArgs.count else {
            throw CLIError(message: "put: sources must be local files", code: .usage)
        }
        for local in srcLocals {
            guard FileManager.default.fileExists(atPath: local) else {
                throw CLIError(message: "put: local file not found: \(local)", code: .failure)
            }
        }
    }

    let deviceId = try selectedDevice(config: config)
    return withOpenDevice(deviceId: deviceId, config: config) { _ in
        let env: Envelope
        var pendingRename: (from: String, to: String)? = nil
        var pendingUploadRename: (path: String, newName: String)? = nil
        var uploadSid: UInt32?

        switch dir {
        case .download:
            let lookup = resolveRemoteStorage(srcRemotes[0], deviceId: deviceId, config: config)
            guard case .ready(let sid, let storage) = lookup else {
                if case .failed(let code) = lookup { return code }
                return .deviceNotFound
            }
            let readCaps = storage["capabilities"] as? [String: Any] ?? [:]
            if bool(readCaps["read"]) != true {
                fputs("Error: storage \"\(string(storage["displayName"]) ?? "?")\" cannot be read. DBI install storages accept files but cannot be listed or read back.\n", stderr)
                return .unsupported
            }
            let sources = srcRemotes.map(\.path)
            let fm = FileManager.default
            if sources.count == 1 {
                // Single source keeps the cp convention: a destination that
                // names a (non-existing) file renames after download.
                let target = downloadTarget(for: destArg, sourcePath: sources[0])
                pendingRename = target.rename
                let dir = (target.directory as NSString).expandingTildeInPath
                try? fm.createDirectory(at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
                env = NxmtpClient.download(deviceId: deviceId, storageId: sid,
                                           sources: [sources[0]], destination: target.directory)
            } else {
                let dir = (destArg as NSString).expandingTildeInPath
                try? fm.createDirectory(at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
                env = NxmtpClient.download(deviceId: deviceId, storageId: sid,
                                           sources: sources, destination: destArg)
            }
        case .upload:
            let remote = destRemote!
            let lookup = resolveRemoteStorage(remote, deviceId: deviceId, config: config)
            guard case .ready(let sid, _) = lookup else {
                if case .failed(let code) = lookup { return code }
                return .deviceNotFound
            }
            uploadSid = sid
            if srcLocals.count == 1 {
                let target = uploadTarget(for: remote.path, storageId: sid,
                                           deviceId: deviceId, sourcePath: srcLocals[0])
                pendingUploadRename = target.rename
                env = NxmtpClient.upload(deviceId: deviceId, storageId: sid,
                                         sources: [srcLocals[0]], destination: target.directory)
            } else {
                env = NxmtpClient.upload(deviceId: deviceId, storageId: sid,
                                         sources: srcLocals, destination: remote.path)
            }
        }

        if config.json { print(env.raw) }
        if !env.isSuccess { printError(env); return exitCode(for: env) }
        if let rename = pendingRename {
            do {
                try applyDownloadRename(rename)
            } catch {
                fputs("Error: \(error.localizedDescription)\n", stderr)
                return .failure
            }
        }
        if let rename = pendingUploadRename, let sid = uploadSid {
            let renameEnv = NxmtpClient.rename(deviceId: deviceId, storageId: sid, path: rename.path, newFileName: rename.newName)
            if !renameEnv.isSuccess { printError(renameEnv); return exitCode(for: renameEnv) }
        }
        if !config.json && !config.quiet { printTransferSummary(env, verb: dir == .download ? "Get" : "Put") }
        return .success
    }
}

/// Splits a user-supplied download destination into the directory the backend
/// should write into and, when the destination names a file, the rename that
/// has to happen afterwards.
private func downloadTarget(for destination: String, sourcePath: String) -> (directory: String, rename: (from: String, to: String)?) {
    if destination.hasSuffix("/") { return (destination, nil) }

    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: destination, isDirectory: &isDirectory), isDirectory.boolValue {
        return (destination, nil)
    }

    let url = URL(fileURLWithPath: destination)
    let newName = url.lastPathComponent
    let sourceName = URL(fileURLWithPath: normalizedRemotePath(sourcePath)).lastPathComponent
    guard !newName.isEmpty, newName != ".", newName != "..", !sourceName.isEmpty else {
        return (destination, nil)
    }

    var parent = url.deletingLastPathComponent().path
    if parent.isEmpty { parent = "." }
    if newName == sourceName { return (parent, nil) }
    return (parent, (from: (parent as NSString).appendingPathComponent(sourceName), to: destination))
}

private func applyDownloadRename(_ rename: (from: String, to: String)) throws {
    let fm = FileManager.default
    guard fm.fileExists(atPath: rename.from) else { return }
    if fm.fileExists(atPath: rename.to) {
        try fm.removeItem(atPath: rename.to)
    }
    try fm.moveItem(atPath: rename.from, toPath: rename.to)
}

/// Splits a user-supplied upload destination into the device directory the
/// backend should write into and, when the destination names a file, the
/// on-device rename that has to happen afterwards.
///
/// This is the upload counterpart of `downloadTarget`. Without it,
/// `cp local.bin 65537:/new-name.bin` created a *folder* called `new-name.bin`
/// on the device and put `local.bin` inside it.
private func uploadTarget(for destination: String, storageId: UInt32, deviceId: String, sourcePath: String)
    -> (directory: String, rename: (path: String, newName: String)?)
{
    let normalized = normalizedRemotePath(destination)
    if destination.hasSuffix("/") || normalized == "/" { return (destination, nil) }

    let newName = (normalized as NSString).lastPathComponent
    let sourceName = URL(fileURLWithPath: sourcePath).lastPathComponent
    guard !newName.isEmpty, newName != ".", newName != "..", !sourceName.isEmpty else {
        return (destination, nil)
    }

    // A directory that already exists on the device is a copy-into target, so
    // there is nothing to rename.
    if remoteIsDirectory(path: normalized, storageId: storageId, deviceId: deviceId) {
        return (destination, nil)
    }

    // Uploading a local directory always produces a directory; treating the
    // destination as a new name for it would be wrong.
    var isSourceDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: sourcePath, isDirectory: &isSourceDirectory), isSourceDirectory.boolValue {
        return (destination, nil)
    }

    var parent = (normalized as NSString).deletingLastPathComponent
    if parent.isEmpty { parent = "/" }
    if newName == sourceName { return (parent, nil) }
    return (parent, (path: (parent as NSString).appendingPathComponent(sourceName), newName: newName))
}

/// Reports whether `path` exists on the device as a directory, by listing its
/// parent and looking for a folder entry of the same name. A non-recursive
/// walk of the parent is one round trip and, unlike `FileExists`, distinguishes
/// files from folders.
private func remoteIsDirectory(path: String, storageId: UInt32, deviceId: String) -> Bool {
    let name = (path as NSString).lastPathComponent
    var parent = (path as NSString).deletingLastPathComponent
    if parent.isEmpty { parent = "/" }

    let env = NxmtpClient.walk(deviceId: deviceId, storageId: storageId, path: parent, skipHidden: false)
    guard env.isSuccess, let entries = env.data as? [[String: Any]] else { return false }
    for entry in entries {
        guard let entryName = string(entry["name"]), entryName == name else { continue }
        return bool(entry["isFolder"]) ?? false
    }
    return false
}

private func handleRm(args: [String], config: Config) throws -> ExitCode {
    guard !args.isEmpty else { throw CLIError(message: "rm expects one or more device paths", code: .usage) }
    var remotes: [RemotePath] = []
    var selector = ""
    for arg in args {
        guard let rp = parseRemote(arg) else {
            throw CLIError(message: "rm expects <storage>:<path>", code: .usage)
        }
        guard normalizedRemotePath(rp.path) != "/" else {
            throw CLIError(message: "refusing to delete a storage root", code: .usage)
        }
        if selector.isEmpty {
            selector = rp.selector
        } else if selector.lowercased() != rp.selector.lowercased() {
            throw CLIError(message: "rm: all paths must be on the same storage", code: .usage)
        }
        remotes.append(rp)
    }
    let deviceId = try selectedDevice(config: config)
    return withOpenDevice(deviceId: deviceId, config: config) { _ in
        let lookup = resolveRemoteStorage(remotes[0], deviceId: deviceId, config: config)
        guard case .ready(let sid, let storage) = lookup else {
            if case .failed(let code) = lookup { return code }
            return .deviceNotFound
        }
        let caps = storage["capabilities"] as? [String: Any] ?? [:]
        if bool(caps["delete"]) != true {
            fputs("Error: storage \"\(string(storage["displayName"]) ?? "?")\" does not allow deleting.\n", stderr)
            return .unsupported
        }
        let paths = remotes.map(\.path)
        let env = NxmtpClient.delete(deviceId: deviceId, storageId: sid, paths: paths)
        if config.json { print(env.raw) }
        if !env.isSuccess { printError(env); return exitCode(for: env) }
        if !config.json && !config.quiet { print("Deleted \(paths.count) item(s) from \(string(storage["displayName"]) ?? selector)") }
        return .success
    }
}

private func handleMv(args: [String], config: Config) throws -> ExitCode {
    guard args.count == 2, let source = parseRemote(args[0]) else {
        throw CLIError(message: "mv expects <storage>:<path> <new-name>", code: .usage)
    }
    let rawSecond = args[1].trimmingCharacters(in: .whitespaces)
    let second = parseRemote(rawSecond)

    if let dest = second {
        guard dest.selector.lowercased() == source.selector.lowercased() else {
            throw CLIError(message: "mv cannot move between storages", code: .usage)
        }
        guard parentPath(dest.path) == parentPath(source.path) else {
            throw CLIError(message: "mv can rename within a directory but cannot move between directories; use get and put instead", code: .usage)
        }
    }

    // A full device path as the second argument is accepted as long as it names
    // the same directory; only its basename is used. A bare local-style name
    // must not contain a path separator.
    let candidate = second?.path ?? rawSecond
    let base = (candidate as NSString).lastPathComponent
    guard !base.isEmpty, base != ".", base != ".." else {
        throw CLIError(message: "\"\(args[1])\" is not a valid new name", code: .usage)
    }
    if second == nil {
        guard !rawSecond.contains("/"), !rawSecond.contains("\\") else {
            throw CLIError(message: "\"\(args[1])\" is not a valid new name", code: .usage)
        }
    }

    let deviceId = try selectedDevice(config: config)
    return withOpenDevice(deviceId: deviceId, config: config) { _ in
        let lookup = resolveRemoteStorage(source, deviceId: deviceId, config: config)
        guard case .ready(let sid, _) = lookup else {
            if case .failed(let code) = lookup { return code }
            return .deviceNotFound
        }
        let env = NxmtpClient.rename(deviceId: deviceId, storageId: sid, path: source.path, newFileName: base)
        if config.json { print(env.raw) }
        if !env.isSuccess { printError(env); return exitCode(for: env) }
        if !config.json && !config.quiet { print("Renamed \(URL(fileURLWithPath: source.path).lastPathComponent) to \(base)") }
        return .success
    }
}

private func handleMkdir(args: [String], config: Config) throws -> ExitCode {
    guard args.count == 1, let remote = parseRemote(args[0]) else {
        throw CLIError(message: "mkdir expects <storage>:<path>", code: .usage)
    }
    guard normalizedRemotePath(remote.path) != "/" else {
        throw CLIError(message: "mkdir needs a path inside the storage, not the storage root", code: .usage)
    }
    let deviceId = try selectedDevice(config: config)
    return withOpenDevice(deviceId: deviceId, config: config) { _ in
        let lookup = resolveRemoteStorage(remote, deviceId: deviceId, config: config)
        guard case .ready(let sid, _) = lookup else {
            if case .failed(let code) = lookup { return code }
            return .deviceNotFound
        }
        let env = NxmtpClient.makeDirectory(deviceId: deviceId, storageId: sid, path: remote.path)
        if config.json { print(env.raw) }
        if !env.isSuccess { printError(env); return exitCode(for: env) }
        if !config.json && !config.quiet { print("Created \(remote.selector):\(normalizedRemotePath(remote.path))") }
        return .success
    }
}

private func handleInstall(args: [String], config: Config) throws -> ExitCode {
    var toNand = false
    var files: [String] = []
    for arg in args {
        if arg == "--nand" || arg == "-nand" { toNand = true }
        else if arg == "--sd" || arg == "-sd" { /* explicit SD; the default target */ }
        else { files.append(arg) }
    }
    guard !files.isEmpty else { throw CLIError(message: "install expects at least one NSP, NSZ, XCI or XCZ file", code: .usage) }
    let allowed = ["nsp", "nsz", "xci", "xcz"]
    for file in files {
        let expanded = NSString(string: file).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw CLIError(message: "cannot read \(file): no such file or directory", code: .failure)
        }
        let ext = URL(fileURLWithPath: expanded).pathExtension.lowercased()
        guard allowed.contains(ext) else { throw CLIError(message: "install only accepts .nsp, .nsz, .xci and .xcz files", code: .usage) }
    }
    let deviceId = try selectedDevice(config: config)
    let kind = toNand ? "nandInstall" : "sdInstall"
    return withOpenDevice(deviceId: deviceId, config: config) { _ in
        let lookup = resolveStorage(kind: kind, deviceId: deviceId, config: config,
                                    missingMessage: "DBI \(toNand ? "NAND" : "SD") install storage was not found. Start DBI's MTP responder on the Switch.")
        guard case .ready(let sid, _) = lookup else {
            if case .failed(let code) = lookup { return code }
            return .deviceNotFound
        }
        if !config.json && !config.quiet {
            print("Uploading to \(toNand ? "NAND" : "SD") install target. Watch the Switch screen after transfer completes.")
        }
        let env = NxmtpClient.upload(deviceId: deviceId, storageId: sid, sources: files, destination: "/")
        if config.json { print(env.raw) }
        if !env.isSuccess { printError(env); return exitCode(for: env) }
        if !config.json && !config.quiet {
            printTransferSummary(env, verb: "Install upload")
            print("Installation continues on the Switch. MTP does not report final installation completion.")
        }
        return .success
    }
}

private func handleBackupSaves(args: [String], config: Config) throws -> ExitCode {
    guard args.count == 1 else { throw CLIError(message: "backup-saves expects a destination directory", code: .usage) }
    let root = NSString(string: args[0]).expandingTildeInPath
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd_HHmmss"
    let destination = (root as NSString).appendingPathComponent("switch-saves-\(formatter.string(from: Date()))")

    let deviceId = try selectedDevice(config: config)
    return withOpenDevice(deviceId: deviceId, config: config) { _ in
        let lookup = resolveStorage(kind: "saves", deviceId: deviceId, config: config,
                                    missingMessage: "Saves storage was not found. Start DBI's MTP responder on the Switch.")
        guard case .ready(let sid, _) = lookup else {
            if case .failed(let code) = lookup { return code }
            return .deviceNotFound
        }
        if !config.json && !config.quiet { print("Backing up saves to \(destination)") }
        let env = NxmtpClient.download(deviceId: deviceId, storageId: sid, sources: ["/"], destination: destination)
        if config.json { print(env.raw) }
        if !env.isSuccess { printError(env); return exitCode(for: env) }
        if !config.json && !config.quiet { printTransferSummary(env, verb: "Backup"); print("Saved to \(destination)") }
        return .success
    }
}

// MARK: - Batch scan / install

private func handleBatch(args: [String], config: Config) throws -> ExitCode {
    guard let sub = args.first else {
        throw CLIError(message: "batch requires 'scan' or 'install'", code: .usage)
    }
    let rest = Array(args.dropFirst())
    switch sub {
    case "scan": return try handleBatchScan(args: rest, config: config)
    case "install": return try handleBatchInstall(args: rest, config: config)
    default:
        throw CLIError(message: "Unknown batch subcommand: \(sub). Use 'scan' or 'install'.", code: .usage)
    }
}

/// Splits batch-install flags from root paths. `--sd` is the default and only
/// accepted for explicitness; `--nand` targets the internal install storage.
private func parseBatchOptions(_ args: [String]) throws -> (roots: [String], nand: Bool, assumeYes: Bool) {
    var roots: [String] = []
    var nand = false
    var sd = false
    var assumeYes = false
    for arg in args {
        switch arg {
        case "--nand", "-nand": nand = true
        case "--sd", "-sd": sd = true
        case "--yes", "-y": assumeYes = true
        default: roots.append(arg)
        }
    }
    guard !(nand && sd) else {
        throw CLIError(message: "batch install accepts either --sd or --nand, not both", code: .usage)
    }
    return (roots, nand, assumeYes)
}

/// Recursively scans the given roots, runs the structural inspector and, when
/// `--keys` was supplied, the deep signature/hash pass. Local only: no console
/// connection is required.
private func scanPackages(roots: [String], config: Config) throws -> [InstallPackage] {
    let urls = roots.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
    for url in urls {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError(message: "Path not found: \(url.path)", code: .failure)
        }
    }

    let packages = BatchScanner.scan(urls: urls)
    guard !packages.isEmpty else { return [] }

    guard let keysPath = config.keysPath else { return packages }

    let keysetURL = URL(fileURLWithPath: NSString(string: keysPath).expandingTildeInPath)
    guard FileManager.default.isReadableFile(atPath: keysetURL.path) else {
        throw CLIError(message: "Keyset not readable: \(keysetURL.path)", code: .failure)
    }
    let attributes = try? KeySetStore.attributes(of: keysetURL.path)
    guard (attributes?.keyCount ?? 0) > 0 else {
        throw CLIError(message: "No 128-bit keys recognized in \(keysetURL.path).", code: .failure)
    }
    guard let hactool = DeepVerifier.hactoolURL else {
        throw CLIError(message: "Bundled hactool not found. Use a complete build or set SWITCHMTP_HACTOOL.", code: .failure)
    }

    let ephemeral: URL
    do {
        ephemeral = try KeySetStore.makeEphemeralCopy(of: keysetURL.path)
    } catch {
        throw CLIError(message: "Could not stage a temporary copy of the keyset: \(error.localizedDescription)", code: .failure)
    }
    defer { KeySetStore.discard(ephemeral) }
    let titleKeys = DeepCheckRunner.titleKeysURL(for: keysetURL.path)
    let jobs = DeepCheckRunner.jobs(for: packages)

    var byID = Dictionary(uniqueKeysWithValues: packages.map { ($0.id, $0) })
    DeepCheckRunner.run(
        jobs: jobs,
        keysetURL: ephemeral,
        titleKeysURL: titleKeys,
        hactoolURL: hactool,
        onProgress: { job, fraction, phase in
            guard !config.json else { return }
            fputs("\r  \(phase) \(Int((fraction * 100).rounded()))%  \(job.url.lastPathComponent)", stderr)
        },
        onResult: { job, result in
            if !config.json { fputs("\n", stderr) }
            guard var package = byID[job.id] else { return }
            package.deepState = result.state
            package.deepNCAs = result.ncas
            package.notes.append(contentsOf: result.notes)
            if result.state == .failed { package.isSelected = false }
            byID[job.id] = package
        })

    return packages.map { byID[$0.id] ?? $0 }
}

private func handleBatchScan(args: [String], config: Config) throws -> ExitCode {
    let (roots, _, _) = try parseBatchOptions(args)
    guard !roots.isEmpty else {
        throw CLIError(message: "batch scan expects one or more files/folders", code: .usage)
    }

    let packages = try scanPackages(roots: roots, config: config)
    let groups = BatchGrouper.group(packages)

    if config.json {
        printBatchJSON(packages: packages, groups: groups)
    } else {
        printBatchTable(packages: packages, groups: groups)
    }
    return .success
}

private func handleBatchInstall(args: [String], config: Config) throws -> ExitCode {
    let (roots, toNand, assumeYes) = try parseBatchOptions(args)
    guard !roots.isEmpty else {
        throw CLIError(message: "batch install expects one or more files/folders", code: .usage)
    }

    let packages = try scanPackages(roots: roots, config: config)
    let blocked = packages.filter { $0.resolvedVerdict == .blocked }
    let eligible = packages.filter(\.isSelectable)
    guard !eligible.isEmpty else {
        throw CLIError(message: "No installable package remains after structural/deep checks.", code: .failure)
    }

    let plan = InstallPlanOrder.ordered(eligible)
    let caution = plan.filter { $0.resolvedVerdict == .caution }.count
    let unverified = plan.filter { $0.resolvedVerdict == .unverified }.count

    if !config.json {
        let planBytes = UInt64(max(0, plan.reduce(0) { $0 + $1.fileSize }))
        print("Plan: \(plan.count) package(s), \(formatBytes(planBytes))"
            + (toNand ? " → NAND" : " → SD"))
        if !blocked.isEmpty {
            fputs("Skipping \(blocked.count) blocked package(s): \(blocked.map(\.url.lastPathComponent).joined(separator: ", "))\n", stderr)
        }
        if caution > 0 {
            fputs("Warning: \(caution) package(s) are not retail-signed (yellow on the console).\n", stderr)
        }
        if unverified > 0 {
            fputs("Note: \(unverified) package(s) were never signature-verified (no keyset or compressed content); they may show up unverified on the console.\n", stderr)
        }
        if !assumeYes {
            fputs("Proceeding with the batch install. Press Ctrl-C to stop.\n", stderr)
        }
    }

    let deviceId = try selectedDevice(config: config)
    return withOpenDevice(deviceId: deviceId, config: config) { _ in
        let kind = toNand ? "nandInstall" : "sdInstall"
        let lookup = resolveStorage(kind: kind, deviceId: deviceId, config: config,
                                    missingMessage: "DBI \(toNand ? "NAND" : "SD") install storage was not found. Start DBI's MTP responder on the Switch.")
        guard case .ready(let sid, _) = lookup else {
            if case .failed(let code) = lookup { return code }
            return .deviceNotFound
        }

        var sent: [String] = []
        var failed: [(String, String)] = []
        let maxAttempts = 3
        var aborted = false

        for package in plan {
            if aborted {
                failed.append((package.url.path, "aborted: previous transfer disconnected"))
                continue
            }
            var lastError = "unknown error"
            var succeeded = false
            for attempt in 1...maxAttempts {
                let env = NxmtpClient.upload(
                    deviceId: deviceId, storageId: sid,
                    sources: [package.url.path], destination: "/")
                if env.isSuccess { succeeded = true; break }
                lastError = env.error.isEmpty ? "transfer failed" : env.error
                if isFatalTransferError(lastError) { aborted = true; break }
                if !config.json {
                    fputs("Retry \(attempt)/\(maxAttempts) for \(package.url.lastPathComponent): \(lastError)\n", stderr)
                }
            }
            if succeeded {
                sent.append(package.url.path)
                if !config.json && !config.quiet { print("Sent \(package.url.lastPathComponent)") }
            } else {
                failed.append((package.url.path, lastError))
                fputs("Failed \(package.url.lastPathComponent): \(lastError)\n", stderr)
            }
        }

        if config.json {
            let result: [String: Any] = [
                "sent": sent,
                "failed": failed.map { ["file": $0.0, "error": $0.1] },
                "note": "MTP does not report final installation completion; verify installed titles on the console."
            ]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                print(text)
            } else {
                fputs("Error: failed to serialize batch result to JSON.\n", stderr)
            }
        } else if !config.quiet {
            print("\nBatch upload finished: \(sent.count) sent, \(failed.count) failed.")
            print("Installation continues on the Switch. MTP does not report final installation completion; verify titles on the console.")
        }
        return failed.isEmpty ? .success : .failure
    }
}

private func verdictLabel(_ verdict: PackageVerdict) -> String {
    switch verdict {
    case .passed: return "PASS"
    case .unverified: return "UNVERIFIED"
    case .caution: return "CAUTION"
    case .blocked: return "BLOCKED"
    case .pending: return "PENDING"
    }
}

private func printBatchTable(packages: [InstallPackage], groups: [InstallPackageGroup]) {
    let bytes = UInt64(max(0, packages.reduce(0) { $0 + $1.fileSize }))
    print("Found \(packages.count) package(s), \(formatBytes(bytes)) in \(groups.count) group(s).")
    for group in groups.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
        print("[\(verdictLabel(group.verdict))] \(group.name)  (\(group.packages.count) item(s), \(group.sizeText))")
        for package in group.packages {
            let type = package.contentType.englishName
            let verdict = verdictLabel(package.resolvedVerdict)
            print("    \(type.padding(toLength: 12, withPad: " ", startingAt: 0)) \(verdict.padding(toLength: 11, withPad: " ", startingAt: 0)) \(package.sizeText.padding(toLength: 12, withPad: " ", startingAt: 0)) \(package.displayName)")
        }
    }
}

private func printBatchJSON(packages: [InstallPackage], groups: [InstallPackageGroup]) {
    func packageEntry(_ package: InstallPackage) -> [String: Any] {
        [
            "file": package.url.path,
            "titleId": package.titleID ?? NSNull(),
            "baseTitleId": package.baseTitleID ?? NSNull(),
            "contentType": package.contentType.rawValue,
            "format": package.format.rawValue,
            "size": package.fileSize,
            "quickVerdict": package.quickVerdict.rawValue,
            "deepState": package.deepState.rawValue,
            "verdict": package.resolvedVerdict.rawValue,
            "selectable": package.isSelectable,
            "notes": package.notes.map { [
                "severity": $0.severity.rawValue, "title": $0.title, "detail": $0.detail
            ] }
        ]
    }
    var counts: [String: Int] = [:]
    for package in packages { counts[package.resolvedVerdict.rawValue, default: 0] += 1 }
    let payload: [String: Any] = [
        "summary": [
            "count": packages.count,
            "bytes": packages.reduce(0) { $0 + $1.fileSize },
            "verdicts": counts
        ],
        "groups": groups.map { [
            "id": $0.id,
            "name": $0.name,
            "packages": $0.packages.map(packageEntry)
        ] },
        "packages": packages.map(packageEntry)
    ]
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    } else {
        fputs("Error: failed to serialize batch result to JSON.\n", stderr)
    }
}

// MARK: - Console bulk workflows

private func datedFolder(parent: String, prefix: String) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd_HHmmss"
    return (parent as NSString).appendingPathComponent("\(prefix)-\(formatter.string(from: Date()))")
}

private func handleRestoreSaves(args: [String], config: Config) throws -> ExitCode {
    guard args.count == 1 else {
        throw CLIError(message: "restore-saves expects a folder previously created by backup-saves", code: .usage)
    }
    let folder = NSString(string: args[0]).expandingTildeInPath
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw CLIError(message: "Not a directory: \(folder)", code: .failure)
    }
    let contents = (try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles])) ?? []
    guard !contents.isEmpty else {
        throw CLIError(message: "That folder is empty — pick a folder created by backup-saves.", code: .failure)
    }

    let deviceId = try selectedDevice(config: config)
    return withOpenDevice(deviceId: deviceId, config: config) { _ in
        let lookup = resolveStorage(kind: "saves", deviceId: deviceId, config: config,
                                    missingMessage: "Saves storage was not found. Enable save access in DBI, then reconnect.")
        guard case .ready(let sid, let storage) = lookup else {
            if case .failed(let code) = lookup { return code }
            return .deviceNotFound
        }
        let capabilities = storage["capabilities"] as? [String: Any]
        if !(bool(capabilities?["write"] as Any?) ?? false) {
            fputs("Error: the Saves storage is read-only. Enable save write access in DBI, then reconnect.\n", stderr)
            return .deviceNotFound
        }
        if !config.json && !config.quiet { print("Restoring \(contents.count) item(s) to the console's save storage.") }
        let env = NxmtpClient.upload(deviceId: deviceId, storageId: sid,
                                     sources: contents.map(\.path), destination: "/")
        if config.json { print(env.raw) }
        if !env.isSuccess { printError(env); return exitCode(for: env) }
        if !config.json && !config.quiet { printTransferSummary(env, verb: "Restore") }
        return .success
    }
}

private func handleExportAlbum(args: [String], config: Config) throws -> ExitCode {
    try handleWholeStorageDownload(kind: "album", prefix: "switch-album", label: "Album", args: args, config: config)
}

private func handleDumpGamecard(args: [String], config: Config) throws -> ExitCode {
    try handleWholeStorageDownload(kind: "gamecard", prefix: "switch-gamecard", label: "Gamecard", args: args, config: config)
}

private func handleWholeStorageDownload(kind: String, prefix: String, label: String,
                                         args: [String], config: Config) throws -> ExitCode {
    guard args.count == 1 else {
        throw CLIError(message: "\(label.lowercased()) expects a destination directory", code: .usage)
    }
    let destination = datedFolder(parent: NSString(string: args[0]).expandingTildeInPath, prefix: prefix)

    let deviceId = try selectedDevice(config: config)
    return withOpenDevice(deviceId: deviceId, config: config) { _ in
        let lookup = resolveStorage(kind: kind, deviceId: deviceId, config: config,
                                    missingMessage: "\(label) storage was not found. Check the Switch and DBI responder.")
        guard case .ready(let sid, _) = lookup else {
            if case .failed(let code) = lookup { return code }
            return .deviceNotFound
        }
        if !config.json && !config.quiet { print("Exporting \(label) to \(destination)") }
        let env = NxmtpClient.download(deviceId: deviceId, storageId: sid, sources: ["/"], destination: destination)
        if config.json { print(env.raw) }
        if !env.isSuccess { printError(env); return exitCode(for: env) }
        if !config.json && !config.quiet { printTransferSummary(env, verb: label); print("Saved to \(destination)") }
        return .success
    }
}

private func withOpenDevice(deviceId: String, config: Config, body: (Envelope) -> ExitCode) -> ExitCode {
    let details = NxmtpClient.initialize(deviceId: deviceId)
    if !details.isSuccess {
        if config.json { print(details.raw) } else { printError(details) }
        return exitCode(for: details)
    }
    SignalGuard.shared.arm(deviceId: deviceId)
    defer {
        SignalGuard.shared.disarm()
        _ = NxmtpClient.dispose(deviceId: deviceId)
    }
    return body(details)
}

/// Errors that will not recover on a quick retry: the device is gone or the
/// transfer was cancelled. Mirrors `ErrorStringLocalizer`'s cancel/disconnect
/// patterns so the CLI does not burn retries against a dead session.
private func isFatalTransferError(_ error: String) -> Bool {
    let lower = error.lowercased()
    return lower.contains("context canceled") ||
           lower.contains("transfer cancelled by user") ||
           lower.contains("cancelled") ||
           error.contains("ErrorDeviceChanged") ||
           error.contains("LIBUSB_ERROR_NO_DEVICE") ||
           error.contains("Device disconnected")
}

private enum StorageLookup {
    case ready(sid: UInt32, storage: [String: Any])
    case failed(ExitCode)
}

private enum SelectorResolution {
    case ready(sid: UInt32, storage: [String: Any])
    case ambiguous([String])
    case unknown
}

/// Resolves a CLI selector against the device's reported storage list.
/// Order mirrors the upstream Go implementation: numeric sid → kind alias →
/// exact display name (case-insensitive) → unique display-name prefix.
/// Ambiguity is reported instead of guessing.
private func resolveSelector(_ selector: String, in storages: [[String: Any]]) -> SelectorResolution {
    let norm = selector.lowercased().trimmingCharacters(in: .whitespaces)
    let names = { (s: [String: Any]) -> String in string(s["displayName"]) ?? "?" }

    // Numeric id is tried first; if it parses as a number but no storage has
    // that sid, stop here instead of falling through to a fuzzy name match —
    // guessing a different storage could write to the wrong place.
    if let id = UInt32(norm) {
        if let match = storages.first(where: { uint32($0["Sid"]) == id }) {
            return .ready(sid: id, storage: match)
        }
        return .unknown
    }

    let aliasKey = norm.replacingOccurrences(of: " ", with: "")
    if let kind = storageAliases[aliasKey] {
        let matches = storages.filter { string($0["kind"]) == kind }
        if matches.count == 1, let sid = uint32(matches[0]["Sid"]) {
            return .ready(sid: sid, storage: matches[0])
        }
        if matches.count > 1 { return .ambiguous(matches.map(names)) }
        return .unknown
    }

    let exact = storages.filter { names($0).lowercased() == norm }
    if exact.count == 1, let sid = uint32(exact[0]["Sid"]) {
        return .ready(sid: sid, storage: exact[0])
    }
    if exact.count > 1 { return .ambiguous(exact.map(names)) }

    let prefix = storages.filter { names($0).lowercased().hasPrefix(norm) }
    if prefix.count == 1, let sid = uint32(prefix[0]["Sid"]) {
        return .ready(sid: sid, storage: prefix[0])
    }
    if prefix.count > 1 { return .ambiguous(prefix.map(names)) }

    return .unknown
}

/// Fetches the storage list inside the open device session and resolves a
/// remote path's selector to a concrete sid. On failure it reports to
/// stderr/JSON and returns `.failed` with the matching exit code.
private func resolveRemoteStorage(_ remote: RemotePath, deviceId: String, config: Config) -> StorageLookup {
    let env = NxmtpClient.fetchStorages(deviceId: deviceId)
    guard env.isSuccess else {
        if config.json { print(env.raw) } else { printError(env) }
        return .failed(exitCode(for: env))
    }
    let storages = storages(from: env)
    switch resolveSelector(remote.selector, in: storages) {
    case .ready(let sid, let storage):
        return .ready(sid: sid, storage: storage)
    case .ambiguous(let names):
        fputs("Error: storage selector \"\(remote.selector)\" matches multiple: \(names.joined(separator: ", ")). Use the numeric id or a more specific name.\n", stderr)
        return .failed(.usage)
    case .unknown:
        let available = storages.map { "\(uint32($0["Sid"]) ?? 0)=\(string($0["displayName"]) ?? "?")" }
        fputs("Error: no storage matches \"\(remote.selector)\". Available: \(available.isEmpty ? "none" : available.joined(separator: ", "))\n", stderr)
        return .failed(.usage)
    }
}

/// Fetch storages and locate the one matching `kind`. Reports the failure
/// envelope or a device-missing diagnostic through stderr/JSON and returns
/// `.failed` with the matching exit code.
private func resolveStorage(kind: String, deviceId: String, config: Config,
                            missingMessage: String) -> StorageLookup {
    let env = NxmtpClient.fetchStorages(deviceId: deviceId)
    guard env.isSuccess else {
        if config.json { print(env.raw) } else { printError(env) }
        return .failed(exitCode(for: env))
    }
    guard let storage = storages(from: env).first(where: { string($0["kind"]) == kind }),
          let sid = uint32(storage["Sid"]) else {
        fputs("Error: \(missingMessage)\n", stderr)
        return .failed(.deviceNotFound)
    }
    return .ready(sid: sid, storage: storage)
}

private func selectedDevice(config: Config) throws -> String {
    if let deviceId = config.deviceId { return deviceId }
    let env = NxmtpClient.fetchDevices()
    if !env.isSuccess { printError(env); throw CLIError(message: "", code: exitCode(for: env)) }
    let usable = devices(from: env).filter { bool($0["usable"]) ?? true }
    if usable.isEmpty {
        throw CLIError(message: "No MTP device is connected. Connect the Switch, open DBI's MTP responder, then try again.", code: .deviceNotFound)
    }
    if usable.count > 1 {
        throw CLIError(message: "Multiple MTP devices are connected. Pass --device <id>.", code: .usage)
    }
    return deviceId(usable[0])
}

private func printDeviceInfo(_ env: Envelope) {
    guard let data = env.data as? [String: Any] else { return }
    print("Device Information")
    print("==================")
    print("Device ID: \(string(data["deviceId"]) ?? "-")")
    print("Name:      \(string(data["displayName"]) ?? "-")")
    print("Profile:   \(string(data["deviceProfile"]) ?? "unknown")")
    if let advice = string(data["advice"]), !advice.isEmpty { print("Hint:      \(advice)") }

    if let mtp = data["mtpDeviceInfo"] as? [String: Any] {
        print("MTP:")
        for key in ["Manufacturer", "Model", "SerialNumber", "DeviceVersion", "MTPExtension"] {
            if let value = string(mtp[key]), !value.isEmpty { print("  \(key): \(value)") }
        }
    }
    if let caps = data["capabilities"] as? [String: Any] {
        let enabled = caps.keys.sorted().filter { bool(caps[$0]) == true }
        print("Capabilities: \(enabled.isEmpty ? "none reported" : enabled.joined(separator: ", "))")
    }
}

private func printStorages(_ env: Envelope) {
    let list = storages(from: env)
    if list.isEmpty { print("No storages reported."); return }
    print("ID          Kind             Capabilities                 FREE        TOTAL       Name")
    for storage in list {
        let sid = String(uint32(storage["Sid"]) ?? 0)
        let kind = string(storage["kind"]) ?? "unknown"
        let caps = capabilityText(storage["capabilities"] as? [String: Any] ?? [:])
        let info = storage["Info"] as? [String: Any] ?? [:]
        let reliable = bool(storage["sizeReliable"]) ?? true
        let total = int64(info["MaxCapability"]) ?? 0
        let freeText: String
        let totalText: String
        if reliable, total > 0 {
            freeText = formatBytes(UInt64(max(int64(info["FreeSpaceInBytes"]) ?? 0, 0)))
            totalText = formatBytes(UInt64(total))
        } else {
            freeText = "—"
            totalText = "—"
        }
        let name = string(storage["displayName"]) ?? storageDescription(storage)
        print("\(sid.padding(toLength: 11, withPad: " ", startingAt: 0)) \(kind.padding(toLength: 16, withPad: " ", startingAt: 0)) \(caps.padding(toLength: 28, withPad: " ", startingAt: 0)) \(freeText.padding(toLength: 11, withPad: " ", startingAt: 0)) \(totalText.padding(toLength: 11, withPad: " ", startingAt: 0)) \(name)")
        var notes: [String] = []
        if bool(storage["virtual"]) == true { notes.append("virtual/generated") }
        if bool((storage["capabilities"] as? [String: Any])?["installTarget"]) == true { notes.append("write-only install trigger") }
        if bool((storage["capabilities"] as? [String: Any])?["browse"]) == false { notes.append("not browsable") }
        if let description = string(storage["description"]), !description.isEmpty { notes.append(description) }
        if !notes.isEmpty { print("  \(notes.joined(separator: "; "))") }
    }
}

private func printListing(_ env: Envelope, showAll: Bool, recursive: Bool) {
    let entries = (env.data as? [[String: Any]] ?? []).filter { showAll || !(string($0["name"]) ?? "").hasPrefix(".") }
    if entries.isEmpty {
        print("(empty)")
        return
    }
    // Directories first, then case-insensitive name order — matches the app list.
    let sorted = entries.sorted { a, b in
        let aDir = bool(a["isFolder"]) ?? false
        let bDir = bool(b["isFolder"]) ?? false
        if aDir != bDir { return aDir }
        return (string(a["name"]) ?? "").lowercased() < (string(b["name"]) ?? "").lowercased()
    }
    var fileCount = 0, dirCount = 0
    var totalBytes: Int64 = 0
    for entry in sorted {
        let isDir = bool(entry["isFolder"]) ?? false
        let sizeText: String
        if isDir {
            dirCount += 1
            sizeText = "<dir>"
        } else if bool(entry["sizeUnknown"]) == true {
            fileCount += 1
            sizeText = "?"
        } else {
            let size = int64(entry["size"]) ?? 0
            totalBytes += size
            fileCount += 1
            sizeText = formatBytes(UInt64(max(size, 0)))
        }
        let date = (string(entry["dateAdded"]) ?? "").isEmpty ? "—" : (string(entry["dateAdded"]) ?? "")
        let name = recursive ? (string(entry["path"]) ?? string(entry["name"]) ?? "") : (string(entry["name"]) ?? "")
        print("\(isDir ? "<DIR>" : "     ") \(sizeText.padding(toLength: 12, withPad: " ", startingAt: 0)) \(date.padding(toLength: 16, withPad: " ", startingAt: 0)) \(name)")
    }
    print("\(fileCount) file(s), \(dirCount) director(y/ies), \(formatBytes(UInt64(max(totalBytes, 0))))")
}

private func printTransferSummary(_ env: Envelope, verb: String) {
    guard let data = env.data as? [String: Any] else { print("\(verb) complete."); return }
    let files = int64(data["totalFiles"]) ?? 0
    let dirs = int64(data["totalDirectories"]) ?? 0
    let bytes = int64(data["totalBytes"]) ?? 0
    let elapsed = double(data["elapsed"]) ?? 0
    print("\(verb) complete: \(files) file(s), \(dirs) director(y/ies), \(formatBytes(UInt64(max(bytes, 0)))) in \(humanDuration(elapsed))")
    if let note = string(data["note"]), !note.isEmpty { print(note) }
    if let skipped = data["skipped"] as? [String], !skipped.isEmpty { print("Skipped: \(skipped.joined(separator: ", "))") }
}

private func printError(_ env: Envelope) {
    let message = env.error.isEmpty ? "Unknown backend error" : env.error
    fputs("Error [\(env.errorType)]: \(message)\n", stderr)
    if let hint = env.hint, !hint.isEmpty { fputs("Hint: \(hint)\n", stderr) }
}

private func exitCode(for env: Envelope) -> ExitCode {
    switch env.errorType {
    // Backend error kinds (backend/nxmtp/errors.go); legacy aliases kept so an
    // older backend still maps sensibly.
    case "noDevice", "disconnected", "deviceNotFound", "deviceDisconnected":
        return .deviceNotFound
    case "invalidInput":
        return .usage
    case "cancelled":
        return .cancelled
    case "deviceBusy":
        return .deviceBusy
    case "operationUnsupported", "unsupported":
        return .unsupported
    default:
        return .failure
    }
}

private func parseRemote(_ value: String) -> RemotePath? {
    guard let colon = value.firstIndex(of: ":") else { return nil }
    let selector = String(value[..<colon]).trimmingCharacters(in: .whitespaces)
    guard !selector.isEmpty else { return nil }
    let pathStart = value.index(after: colon)
    let rawPath = String(value[pathStart...])
    let path = normalizedRemotePath(rawPath)
    return RemotePath(selector: selector, path: path, storageId: UInt32(selector))
}

private func normalizedRemotePath(_ path: String) -> String {
    var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "/" }
    trimmed = trimmed.replacingOccurrences(of: "\\", with: "/")
    if !trimmed.hasPrefix("/") { trimmed = "/\(trimmed)" }
    // Collapse repeated slashes and resolve . / .. segments, mirroring path.Clean.
    var stack: [String] = []
    for segment in trimmed.components(separatedBy: "/") {
        switch segment {
        case "", ".": continue
        case "..": if !stack.isEmpty { stack.removeLast() }
        default: stack.append(segment)
        }
    }
    let cleaned = stack.joined(separator: "/")
    return cleaned.isEmpty ? "/" : "/\(cleaned)"
}

private func parentPath(_ path: String) -> String {
    let normalized = normalizedRemotePath(path)
    guard normalized != "/" else { return "/" }
    let ns = normalized as NSString
    let parent = ns.deletingLastPathComponent
    return parent.isEmpty ? "/" : parent
}

private func devices(from env: Envelope) -> [[String: Any]] {
    env.data as? [[String: Any]] ?? []
}

private func storages(from env: Envelope) -> [[String: Any]] {
    env.data as? [[String: Any]] ?? []
}

private func deviceId(_ device: [String: Any]) -> String {
    let vendor = uint32(device["vendorId"]) ?? 0
    let product = uint32(device["productId"]) ?? 0
    let serial = string(device["serialNumber"]) ?? ""
    return "\(vendor)|\(product)|\(serial)"
}

private func storageDescription(_ storage: [String: Any]) -> String {
    if let info = storage["Info"] as? [String: Any] {
        return string(info["StorageDescription"]) ?? string(info["VolumeLabel"]) ?? "Storage"
    }
    return "Storage"
}

private func capabilityText(_ caps: [String: Any]) -> String {
    var values: [String] = []
    for key in ["browse", "read", "write", "delete", "rename", "makeDirectory", "installTarget"] {
        if bool(caps[key]) == true { values.append(key) }
    }
    return values.isEmpty ? "none" : values.joined(separator: ",")
}

private func jsonString(_ value: [String: Any]) -> String? {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: []) else { return nil }
    return String(data: data, encoding: .utf8)
}

private func humanDuration(_ seconds: Double) -> String {
    if seconds < 0 { return "—" }
    let total = Int(seconds.rounded())
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    if h > 0 { return String(format: "%dh%02dm%02ds", h, m, s) }
    if m > 0 { return String(format: "%dm%02ds", m, s) }
    return "\(s)s"
}

private func formatBytes(_ bytes: UInt64) -> String {
    // Decimal units (1000), matching DBI and SD-card vendors, which quote GB
    // as 10^9; binary 1024 would disagree with the number shown on the console.
    if bytes < 1000 { return "\(bytes) B" }
    let units = ["kB", "MB", "GB", "TB", "PB"]
    var div: Double = 1000
    var unit = 0
    var rest = Double(bytes) / 1000
    while rest >= 1000, unit < units.count - 1 {
        div *= 1000
        unit += 1
        rest /= 1000
    }
    let size = Double(bytes) / div
    if size < 10 { return String(format: "%.2f %@", size, units[unit]) }
    if size < 100 { return String(format: "%.1f %@", size, units[unit]) }
    return String(format: "%.0f %@", size, units[unit])
}

private func string(_ value: Any?) -> String? {
    switch value {
    case let value as String: return value
    case let value as NSNumber: return value.stringValue
    default: return nil
    }
}

private func bool(_ value: Any?) -> Bool? {
    switch value {
    case let value as Bool: return value
    case let value as NSNumber: return value.boolValue
    case let value as String: return ["true", "yes", "1"].contains(value.lowercased())
    default: return nil
    }
}

private func int64(_ value: Any?) -> Int64? {
    switch value {
    case let value as NSNumber: return value.int64Value
    case let value as String: return Int64(value)
    default: return nil
    }
}

private func uint32(_ value: Any?) -> UInt32? {
    switch value {
    case let value as NSNumber: return UInt32(truncating: value)
    case let value as String: return UInt32(value)
    default: return nil
    }
}

private func double(_ value: Any?) -> Double? {
    switch value {
    case let value as NSNumber: return value.doubleValue
    case let value as String: return Double(value)
    default: return nil
    }
}

exit(run().rawValue)
