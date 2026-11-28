// SwitchMTP Batch — a macOS MTP client for Nintendo Switch running DBI.
// Copyright (C) 2025 fratei
//
// This program is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License version 2 as published by
// the Free Software Foundation.
//
// Cached deep-verification conclusions between launches, keyed on a cheap
// file fingerprint rather than a full byte hash. A same-name, same-size file
// that was replaced (re-downloaded, repacked) gets a different fingerprint
// because its mtime and/or container entry table differ, so a stale green
// verdict is never handed to the swapped-in package.

import Foundation

/// Cheap identity fingerprint for one package. Uses only stat(2) plus the
/// entry table the structural pass already parsed; no package bytes are read
/// here.
struct PackageFingerprint: Equatable, Sendable {
    let size: Int64
    let mtime: Int64
    let entryKey: String

    var cacheKey: String { "\(size)|\(mtime)|\(entryKey)" }

    static func make(for package: InstallPackage) -> PackageFingerprint? {
        guard let report = package.report else { return nil }
        let values = try? package.url.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize.map(Int64.init) ?? package.fileSize
        let mtime = Int64((values?.contentModificationDate ?? .now).timeIntervalSince1970)
        let entryKey = report.entries
            .map { "\($0.name):\($0.offset):\($0.size)" }
            .joined(separator: ",")
        return PackageFingerprint(size: size, mtime: mtime, entryKey: entryKey)
    }
}

/// On-disk note, kept free of any UUID so the JSON stays small and diffable.
struct NoteDTO: Codable, Sendable {
    var severity: String
    var title: String
    var detail: String
}

struct NCADTO: Codable, Sendable {
    var name: String
    var signature: String
    var hash: String
    var keyRevision: String?
    var note: String?
    var isTitleKeyMissing: Bool
    var unknownKeyGeneration: Bool
    var hardHashFail: Bool
    var levelHashFail: Bool
    var contentUnconfirmed: Bool
    var partialHash: Bool
    var failedLevels: [Int]
}

struct CachedDeepResult: Codable, Sendable {
    var state: String
    var detail: String
    var notes: [NoteDTO]
    var ncas: [NCADTO]
    var checkedAt: Date
    var keyset: String
    /// Control NCA NACP 里的点分显示版本；旧版缓存没有此字段，解码为 nil。
    var displayVersion: String?
}

struct CacheDocument: Codable, Sendable {
    var entries: [String: CachedDeepResult]
}

/// Persisted deep-check conclusions. Only the deep axis is cached; the quick
/// structural verdict is recomputed on every scan because it is nearly free.
final class DeepCheckCache {
    static let shared = DeepCheckCache()

    private var entries: [String: CachedDeepResult] = [:]
    private let storeURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        storeURL = base
            .appendingPathComponent("SwitchMTP Batch", isDirectory: true)
            .appendingPathComponent("DeepCheckCache.json")
        load()
    }

    /// Stable fingerprint for the active keyset. Only path + size + mtime are
    /// recorded; key material never enters the cache. A different keyset
    /// invalidates every cached conclusion.
    static func keysetFingerprint(path: String?) -> String {
        guard let path, FileManager.default.isReadableFile(atPath: path) else { return "" }
        let values = try? URL(fileURLWithPath: path).resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize.map(Int64.init) ?? -1
        let mtime = Int64((values?.contentModificationDate ?? .now).timeIntervalSince1970)
        return "\(path)|\(size)|\(mtime)"
    }

    func result(for fingerprint: PackageFingerprint, keyset: String) -> CachedDeepResult? {
        guard let cached = entries[fingerprint.cacheKey], cached.keyset == keyset else { return nil }
        return cached
    }

    func store(state: DeepCheckState,
               detail: String,
               notes: [CheckNote],
               ncas: [DeepVerifier.NCACheck],
               keyset: String,
               displayVersion: String? = nil,
               for fingerprint: PackageFingerprint) {
        let result = CachedDeepResult(
            state: state.rawValue,
            detail: detail,
            notes: notes.map { NoteDTO(severity: $0.severity.rawValue, title: $0.title, detail: $0.detail) },
            ncas: ncas.map { nca in
                NCADTO(
                    name: nca.name,
                    signature: nca.signature.rawValue,
                    hash: nca.hash.rawValue,
                    keyRevision: nca.keyRevision,
                    note: nca.note,
                    isTitleKeyMissing: nca.isTitleKeyMissing,
                    unknownKeyGeneration: nca.unknownKeyGeneration,
                    hardHashFail: nca.hardHashFail,
                    levelHashFail: nca.levelHashFail,
                    contentUnconfirmed: nca.contentUnconfirmed,
                    partialHash: nca.partialHash,
                    failedLevels: nca.failedLevels)
            },
            checkedAt: Date(),
            keyset: keyset,
            displayVersion: displayVersion)
        entries[fingerprint.cacheKey] = result
        persist()
    }

    /// Restore a cached result into a package's deep state. The notes the quick
    /// structural pass wrote this scan are kept; the cached deep notes are appended.
    func apply(_ cached: CachedDeepResult, to package: inout InstallPackage) {
        let quickNotes = package.notes
        package.deepState = DeepCheckState(rawValue: cached.state) ?? .unavailable
        package.deepNCAs = cached.ncas.map { dto in
            var nca = DeepVerifier.NCACheck(name: dto.name)
            nca.signature = DeepVerifier.NCACheck.Verdict(rawValue: dto.signature) ?? .unknown
            nca.hash = DeepVerifier.NCACheck.Verdict(rawValue: dto.hash) ?? .unknown
            nca.keyRevision = dto.keyRevision
            nca.note = dto.note
            nca.isTitleKeyMissing = dto.isTitleKeyMissing
            nca.unknownKeyGeneration = dto.unknownKeyGeneration
            nca.hardHashFail = dto.hardHashFail
            nca.levelHashFail = dto.levelHashFail
            nca.contentUnconfirmed = dto.contentUnconfirmed
            nca.partialHash = dto.partialHash
            nca.failedLevels = dto.failedLevels
            return nca
        }
        let deepNotes = cached.notes.map {
            CheckNote(severity: CheckSeverity(rawValue: $0.severity) ?? .note,
                      title: $0.title, detail: $0.detail)
        }
        package.notes = quickNotes + deepNotes
        package.displayVersion = cached.displayVersion
        package.deepProgress = 1
        package.deepPhase = nil
    }

    /// Drops every cached conclusion. Used when the keyset is removed, and as
    /// the backing for a manual "re-check" action.
    func invalidateAll() {
        entries.removeAll()
        persist()
    }

    /// Drops conclusions derived under a different keyset; keeps the current one.
    func invalidateKeyset(_ keyset: String) {
        entries = entries.filter { $0.value.keyset == keyset }
        persist()
    }

    /// Remove the cached conclusion for one package, so the next deep pass
    /// re-checks it even if the fingerprint still matches.
    func invalidate(fingerprint: PackageFingerprint) {
        entries.removeValue(forKey: fingerprint.cacheKey)
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let doc = try? JSONDecoder().decode(CacheDocument.self, from: data) else { return }
        entries = doc.entries
    }

    private func persist() {
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: storeURL)
            return
        }
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(CacheDocument(entries: entries)).write(to: storeURL, options: .atomic)
        } catch {
            // A cache write failing must never break a scan or install.
        }
    }
}
