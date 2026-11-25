// SwitchMTP — a macOS MTP client for Nintendo Switch running DBI.
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

// Pure pieces of the install queue, kept out of the MTPManager extension so
// they can be tested without a console attached.

import Foundation

/// What should happen to an install that just failed.
///
/// The difference between "retry this title" and "give up on this title" is the
/// whole point of unattended batching; getting it wrong either loops forever
/// or drops titles silently.
enum InstallRetryPolicy: Equatable {
    case retry
    case fail
    case cancelled

    /// - Parameters:
    ///   - attempts: uploads already started for this file (1 after the first).
    ///   - isCancelled: the user pressed Cancel, not the console failing.
    ///   - maxAttempts: the configured ceiling.
    static func decision(attempts: Int, isCancelled: Bool, maxAttempts: Int = 3) -> InstallRetryPolicy {
        if isCancelled { return .cancelled }
        return attempts < maxAttempts ? .retry : .fail
    }
}

/// The on-disk form of the queue, kept deliberately small: three fields are
/// enough to resume a file, and anything else would go stale between launches.
enum InstallQueueStore {
    struct Entry: Codable, Equatable, Sendable {
        let path: String
        let storageKind: String
        let attempts: Int
    }

    struct Document: Codable, Equatable, Sendable {
        var entries: [Entry]
    }

    static func load(from url: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return [] }
        return doc.entries
    }

    /// Returns false when the file could not be written; the caller decides
    /// whether that is worth surfacing. Removing the file is not a failure.
    @discardableResult
    static func save(_ entries: [Entry], to url: URL) -> Bool {
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return true
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Document(entries: entries)).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
