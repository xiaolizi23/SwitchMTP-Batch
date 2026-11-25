// SwitchMTP Batch — a macOS MTP client for Nintendo Switch running DBI.
// Copyright (C) 2025 fratei
//
// This program is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License version 2 as published by
// the Free Software Foundation.

// Handling of the user's own `prod.keys`.
//
// The file is never copied into the app bundle, never written to preferences,
// never logged, and never included in a report. Two narrow exceptions are
// unavoidable because the verification engine is a separate process:
//
//   1. It must be readable by path, so only its path is remembered.
//   2. hactool accepts a keyset only as a file path, so a short-lived copy with
//      0600 permissions is created in the app's private temporary directory and
//      removed as soon as the check finishes.
//
// Both are documented in the workspace UI rather than hidden in a log.

import Foundation

enum KeySetStore {

    struct Attributes {
        var keyCount: Int
        var hasHeaderKey: Bool
        var hasTicketKeys: Bool
        var keyGenerationHint: Int?
    }

    /// Parses a keyset just far enough to say whether it looks usable. No key
    /// bytes are returned, and nothing parsed here leaves this function.
    static func attributes(of path: String) throws -> Attributes {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var count = 0
        var hasHeader = false
        var hasTicket = false
        var maxGeneration: Int?

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            // A 128-bit key is 32 hex digits. Anything else (paths, comments,
            // blank values) is ignored rather than rejected wholesale, because
            // real keysets often carry extra sections.
            guard value.count == 32, value.allSatisfy({ $0.isHexDigit }) else { continue }
            count += 1
            if name == "header_key" { hasHeader = true }
            if name.hasPrefix("titlekek") { hasTicket = true }
            if name.hasPrefix("key_area_key") || name.hasPrefix("master_key") {
                if let digits = name.split(separator: "_").last, let value = Int(digits, radix: 16) {
                    maxGeneration = max(maxGeneration ?? 0, value)
                }
            }
        }
        return Attributes(keyCount: count, hasHeaderKey: hasHeader,
                          hasTicketKeys: hasTicket, keyGenerationHint: maxGeneration)
    }

    /// Creates the one-time keyset copy hactool needs. The caller owns deletion.
    static func makeEphemeralCopy(of path: String) throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SwitchMTPBatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let destination = folder.appendingPathComponent("keyset.txt")
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard FileManager.default.createFile(atPath: destination.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw NSError(domain: "KeySetStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建临时密钥文件"])
        }
        return destination
    }

    /// Removes the temporary directory holding a keyset copy, best effort.
    static func discard(_ keysetURL: URL) {
        try? FileManager.default.removeItem(at: keysetURL.deletingLastPathComponent())
    }
}
