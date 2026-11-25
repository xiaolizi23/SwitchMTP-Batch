// SwitchMTP Batch — a macOS MTP client for Nintendo Switch running DBI.
// Copyright (C) 2025 fratei
//
// This program is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License version 2 as published by
// the Free Software Foundation.

// NSZ → NSP conversion, backed by the bundled `nszunpack` helper.
//
// NSZ is a normal PFS0 container whose NCAs were swapped for NCZ: the same
// NCA header, then a zstd-compressed body that has to be re-encrypted with the
// section keys recorded in the NCZ. The helper does that and then proves it
// worked by hashing every rebuilt NCA and comparing the digest with the
// `<Id>`/`<Hash>` pairs in the package's own CNMT XML — the byte-for-byte
// ground truth that DBI would check. `NSZ_HASH ... match=yes` is therefore
// stronger evidence than any signature-shaped guess.
//
// Output contract (see tools/nszunpack/nszunpack.c):
//   NSZ_ENTRY: ...            (info)
//   NSZ_PROGRESS: unpacking <entry>
//   NSZ_HASH: <nca> sha256=<hex> expected=<hex|none> match=yes|no|unknown
//   NSZ_HASH_SUMMARY: match=<n> mismatch=<n> unknown=<n>
//   NSZ_CONVERTED: <path>
//   NSZ_OK
//   NSZ_ERROR: <reason>

import Foundation

enum NSZUnpacker {

    static let executableName = "nszunpack"

    /// Bundled next to hactool in `Contents/Resources/bin`; the environment
    /// override lets a development build use a freshly compiled binary.
    static var toolURL: URL? {
        if let override = ProcessInfo.processInfo.environment["SWITCHMTP_NSZUNPACK"],
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        let candidates: [URL?] = [
            Bundle.main.url(forResource: executableName, withExtension: nil, subdirectory: "bin"),
            Bundle.main.url(forResource: executableName, withExtension: nil),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin/\(executableName)")
        ]
        for candidate in candidates {
            if let url = candidate, FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    /// One NCA re-hashed after decompression.
    struct HashVerdict: Sendable, Hashable {
        enum Match: String, Sendable {
            case yes, no, unknown
        }
        let ncaName: String
        let sha256: String
        let expected: String?
        let match: Match

        /// NCA entries are named `<content id>.nca`; the id is what the CNMT,
        /// the hactool block and the NCZ name all share, so it is the join key.
        var contentID: String {
            String(ncaName.prefix(32)).lowercased()
        }
    }

    struct Conversion {
        var outputURL: URL
        var hashes: [HashVerdict]
        var entries: Int
        var duration: TimeInterval
        var log: String

        var matchedCount: Int { hashes.filter { $0.match == .yes }.count }
        var mismatchedCount: Int { hashes.filter { $0.match == .no }.count }
        var unknownCount: Int { hashes.filter { $0.match == .unknown }.count }

        var summaryText: String {
            if matchedCount == 0 && mismatchedCount == 0 {
                return "包内没有 CNMT XML，\(hashes.count) 个 NCA 没有哈希可对照（内容哈希交由引擎在解包后的 NSP 上校验）"
            }
            return "\(matchedCount)/\(hashes.count) 个 NCA 的 SHA-256 与包内 CNMT 清单一致"
                + (mismatchedCount > 0 ? "，\(mismatchedCount) 个不一致" : "")
                + (unknownCount > 0 ? "，\(unknownCount) 个无哈希可对照" : "")
        }
    }

    enum Failure: LocalizedError {
        case toolMissing
        case notNSZ
        case unpackFailed(String)
        case outputMissing

        var errorDescription: String? {
            switch self {
            case .toolMissing:
                return "应用包内缺少 nszunpack 解包工具（Contents/Resources/bin）。重新构建或重新下载发布包即可。"
            case .notNSZ:
                return "解包工具报告这不是一个 NSZ 容器。"
            case .unpackFailed(let message):
                return message
            case .outputMissing:
                return "解包工具结束但没有产出 NSP。"
            }
        }
    }

    // MARK: - Running

    static func unpack(url: URL, to destination: URL, tool: URL,
                       timeout: TimeInterval = 7200) throws -> Conversion {
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // Leftover from a killed run: start clean so a truncated file is never
        // mistaken for this run's output.
        try? FileManager.default.removeItem(at: destination)

        let started = Date()
        let output: String
        switch DeepVerifier.run(tool, arguments: ["unpack", url.path, destination.path], timeout: timeout) {
        case .failure(let message):
            throw Failure.unpackFailed(message)
        case .success(let text):
            output = text
        }

        if let error = firstLine(output, prefix: "NSZ_ERROR:") {
            throw Failure.unpackFailed(error)
        }
        guard output.contains("NSZ_OK") else {
            throw Failure.unpackFailed(firstLine(output, prefix: "NSZ_ERROR:")
                                       ?? "解包工具没有给出 NSZ_OK，可能中途失败。")
        }
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw Failure.outputMissing
        }

        let hashes = parseHashes(output)
        let entries = markerInt("NSZ_ENTRIES", in: output) ?? hashes.count
        return Conversion(outputURL: destination,
                          hashes: hashes,
                          entries: entries,
                          duration: Date().timeIntervalSince(started),
                          log: output)
    }

    /// A scratch path under the system temp directory. Verification uses this
    /// and deletes the NSP afterwards; a big title briefly needs its unpacked
    /// size on disk, which is the honest cost of checking the real bytes.
    static func scratchURL(named name: String) -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("switchmtp-nsz", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = sanitised(name)
        return folder.appendingPathComponent("\(base)-\(UUID().uuidString.prefix(8)).nsp")
    }

    static func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        // The helper leaves <out>.nszwork next to the output.
        let work = URL(fileURLWithPath: url.path + ".nszwork")
        try? FileManager.default.removeItem(at: work)
    }

    private static func sanitised(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let text = String(cleaned.prefix(60))
        return text.isEmpty ? "package" : text
    }

    // MARK: - Output parsing

    static func parseHashes(_ output: String) -> [HashVerdict] {
        var results: [HashVerdict] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("NSZ_HASH:") else { continue }
            let payload = line.replacingOccurrences(of: "NSZ_HASH:", with: "")
                .trimmingCharacters(in: .whitespaces)
            var name = ""
            var digest = ""
            var expected: String?
            var match: HashVerdict.Match = .unknown
            for token in payload.split(separator: " ") {
                let pair = token.split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else {
                    if name.isEmpty { name = String(token) }
                    continue
                }
                let key = String(pair[0])
                let value = String(pair[1])
                switch key {
                case "sha256": digest = value
                case "expected": expected = (value == "none" ? nil : value)
                case "match": match = HashVerdict.Match(rawValue: value) ?? .unknown
                default:
                    if name.isEmpty { name = key }
                }
            }
            guard !name.isEmpty, !digest.isEmpty else { continue }
            results.append(HashVerdict(ncaName: name, sha256: digest, expected: expected, match: match))
        }
        return results
    }

    private static func markerInt(_ marker: String, in output: String) -> Int? {
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("\(marker):") else { continue }
            let payload = line.replacingOccurrences(of: "\(marker):", with: "")
            let first = payload.split(whereSeparator: { $0 == " " || $0 == "," }).first.map(String.init)
            if let value = first, let number = Int(value) { return number }
        }
        return nil
    }

    private static func firstLine(_ output: String, prefix: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(prefix) }?
            .replacingOccurrences(of: prefix, with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}
