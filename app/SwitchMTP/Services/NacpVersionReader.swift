// SwitchMTP Batch — a macOS MTP client for Nintendo Switch running DBI.
// Copyright (C) 2026 fratei
//
// This program is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License version 2 as published by
// the Free Software Foundation.
//
// Reads the console-visible dotted version (`4.0.1`) from the package's own
// Control NCA, as opposed to the CNMT build number (`1507328`), which is a
// separate, internal incrementing number.
//
// Source: Control NCA → RomFS → `control.nacp`, the `display_version` field at
// offset `0x3060` (16 bytes ASCII). DLC packages carry no Control NCA and so
// have no display version. The reader only decrypts what hactool already
// decrypts for the deep pass; every failure returns nil honestly — it never
// invents a version string.

import Foundation

enum NacpVersionReader {

    private static let nacpVersionOffset = 0x3060
    private static let nacpVersionLength = 16

    /// Reads the display version for `url`. Nil when there is no Control NCA
    /// (DLC), the NACP cannot be decrypted/read, or the field is blank.
    static func displayVersion(url: URL,
                               format: PackageFormat,
                               keysetURL: URL,
                               titleKeysURL: URL?,
                               hactoolURL: URL) -> String? {
        switch format {
        case .nsp:
            return nspDisplayVersion(url: url, keysetURL: keysetURL,
                                     titleKeysURL: titleKeysURL, hactoolURL: hactoolURL)
        case .xci:
            return xciDisplayVersion(url: url, keysetURL: keysetURL,
                                     titleKeysURL: titleKeysURL, hactoolURL: hactoolURL)
        case .nsz, .xcz:
            // Compressed titles are unpacked by the deep pass into a rebuilt NSP;
            // the reader runs against that inner NSP, so nothing to do here.
            return nil
        }
    }

    // MARK: - NSP

    private static func nspDisplayVersion(url: URL, keysetURL: URL,
                                          titleKeysURL: URL?, hactoolURL: URL) -> String? {
        // Step 1: ask hactool which NCA is the Control one.
        let probe = DeepVerifier.run(hactoolURL,
                                     arguments: baseArgs(keysetURL, titleKeysURL) + ["-t", "nsp", "-i", url.path],
                                     timeout: 600)
        guard let output = probe.successText,
              let controlName = controlNCAName(in: output) else { return nil }

        // Step 2: locate that NCA's range in the outer PFS0 table.
        guard let entries = pfs0Entries(of: url),
              let entry = entries[controlName] else { return nil }

        let tmp = makeScratchDir()
        defer { removeScratchDir(tmp) }
        let ncaURL = tmp.appendingPathComponent("control.nca")
        guard let ncaData = readRange(of: url, offset: entry.offset, count: Int(entry.size)),
              (try? ncaData.write(to: ncaURL, options: .atomic)) != nil else { return nil }

        // Step 3: unpack the Control NCA RomFS and read the NACP field.
        return unpackRomFSAndReadVersion(ncaURL: ncaURL, keysetURL: keysetURL,
                                         titleKeysURL: titleKeysURL, hactoolURL: hactoolURL,
                                         scratch: tmp)
    }

    // MARK: - XCI

    private static func xciDisplayVersion(url: URL, keysetURL: URL,
                                          titleKeysURL: URL?, hactoolURL: URL) -> String? {
        let tmp = makeScratchDir()
        defer { removeScratchDir(tmp) }
        let secured = tmp.appendingPathComponent("secured")
        try? FileManager.default.createDirectory(at: secured, withIntermediateDirectories: true)

        let extract = DeepVerifier.run(hactoolURL,
                                       arguments: baseArgs(keysetURL, titleKeysURL) + ["-t", "xci", "--securedir", secured.path, url.path],
                                       timeout: 900)
        guard extract.successText != nil else { return nil }

        let ncas = (try? FileManager.default.contentsOfDirectory(at: secured, includingPropertiesForKeys: nil)) ?? []
        for nca in ncas where nca.pathExtension == "nca" {
            let probe = DeepVerifier.run(hactoolURL,
                                         arguments: baseArgs(keysetURL, titleKeysURL) + ["-t", "nca", "-i", nca.path],
                                         timeout: 300)
            guard let output = probe.successText, isControlNCA(output: output) else { continue }
            if let version = unpackRomFSAndReadVersion(ncaURL: nca, keysetURL: keysetURL,
                                                       titleKeysURL: titleKeysURL, hactoolURL: hactoolURL,
                                                       scratch: tmp) {
                return version
            }
        }
        return nil
    }

    // MARK: - Shared RomFS extraction

    private static func unpackRomFSAndReadVersion(ncaURL: URL, keysetURL: URL,
                                                  titleKeysURL: URL?, hactoolURL: URL,
                                                  scratch: URL) -> String? {
        let romfs = scratch.appendingPathComponent("romfs-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: romfs, withIntermediateDirectories: true)

        let extract = DeepVerifier.run(hactoolURL,
                                       arguments: baseArgs(keysetURL, titleKeysURL) + ["-t", "nca", "--romfsdir", romfs.path, ncaURL.path],
                                       timeout: 600)
        guard extract.successText != nil else { return nil }

        guard let nacpURL = findNacp(in: romfs) else { return nil }
        return readDisplayVersion(nacpURL: nacpURL)
    }

    private static func findNacp(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        return files.first { $0.pathExtension.lowercased() == "nacp" }
    }

    private static func readDisplayVersion(nacpURL: URL) -> String? {
        guard let data = try? Data(contentsOf: nacpURL),
              data.count >= nacpVersionOffset + 1 else { return nil }
        let end = min(nacpVersionOffset + nacpVersionLength, data.count)
        let slice = data[nacpVersionOffset..<end]
        let field = slice.split(separator: 0x00).first ?? slice
        guard let version = String(data: field, encoding: .ascii)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              PackageInspector.isValidDisplayVersion(version) else { return nil }
        return version
    }

    // MARK: - Output parsing

    /// Tracks the current NCA across `NSP_NCA_BEGIN:` blocks and remembers the
    /// first one whose `Content Type` is `Control`.
    private static func controlNCAName(in output: String) -> String? {
        var current: String?
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("NSP_NCA_BEGIN:") {
                current = line.dropFirst("NSP_NCA_BEGIN:".count)
                    .trimmingCharacters(in: .whitespaces)
                continue
            }
            if let current, isControlLine(line) { return current }
        }
        return nil
    }

    private static func isControlNCA(output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { isControlLine($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func isControlLine(_ line: String) -> Bool {
        guard line.contains("Content Type:") else { return false }
        return line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) == "Control"
    }

    // MARK: - PFS0 table

    private struct EntryRange { let offset: Int64; let size: Int64 }

    /// Minimal PFS0 walker: header 16 bytes, 24-byte rows (`offset` u64, `size`
    /// u64, string offset u32, reserved u32), then the string table.
    private static func pfs0Entries(of url: URL) -> [String: EntryRange]? {
        guard let header = readRange(of: url, offset: 0, count: 16),
              header.count == 16, header.magic(at: 0, length: 4) == "PFS0" else { return nil }
        let count = Int(header.u32(at: 4))
        let stringTableSize = Int(header.u32(at: 8))
        guard count > 0, count <= 4096, stringTableSize >= 0, stringTableSize <= 16 * 1024 * 1024 else { return nil }

        let entryTableSize = count * 24
        guard let entriesData = readRange(of: url, offset: 16, count: entryTableSize) else { return nil }
        guard let stringTable = readRange(of: url, offset: Int64(16 + entryTableSize), count: stringTableSize) else { return nil }
        let dataStart = Int64(16 + entryTableSize + stringTableSize)

        var out: [String: EntryRange] = [:]
        for index in 0..<count {
            let row = index * 24
            guard entriesData.count >= row + 24 else { break }
            let offset = Int64(clamping: entriesData.u64(at: row))
            let size = Int64(clamping: entriesData.u64(at: row + 8))
            let nameOffset = Int(entriesData.u32(at: row + 16))
            guard let name = stringTable.nulString(at: nameOffset), !name.isEmpty else { continue }
            out[name] = EntryRange(offset: dataStart + offset, size: size)
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Plumbing

    private static func baseArgs(_ keysetURL: URL, _ titleKeysURL: URL?) -> [String] {
        var args = ["-k", keysetURL.path]
        if let titleKeysURL { args += ["--titlekeys", titleKeysURL.path] }
        return args
    }

    private static func readRange(of url: URL, offset: Int64, count: Int) -> Data? {
        guard count > 0,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: count)
        } catch { return nil }
    }

    private static func makeScratchDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("switchmtp-nacp-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func removeScratchDir(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }
}

private extension DeepVerifier.RunOutcome {
    var successText: String? {
        if case .success(let text) = self { return text }
        return nil
    }
}

private extension Data {
    func u32(at offset: Int) -> UInt32 {
        guard count >= offset + 4 else { return 0 }
        let base = startIndex + offset
        return UInt32(self[base])
            | (UInt32(self[base + 1]) << 8)
            | (UInt32(self[base + 2]) << 16)
            | (UInt32(self[base + 3]) << 24)
    }

    func u64(at offset: Int) -> UInt64 {
        let low = UInt64(u32(at: offset))
        let high = UInt64(u32(at: offset + 4))
        return low | (high << 32)
    }

    func magic(at offset: Int, length: Int) -> String? {
        guard offset >= 0, offset + length <= count else { return nil }
        return String(bytes: self[startIndex + offset ..< startIndex + offset + length], encoding: .utf8)
    }

    func nulString(at offset: Int) -> String? {
        guard offset >= 0, offset < count else { return nil }
        let base = startIndex + offset
        var end = base
        while end < endIndex, self[end] != 0 { end += 1 }
        return String(bytes: self[base..<end], encoding: .utf8)
    }
}
