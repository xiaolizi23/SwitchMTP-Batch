// SwitchMTP Batch — a macOS MTP client for Nintendo Switch running DBI.
// Copyright (C) 2026 fratei
//
// This program is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License version 2 as published by
// the Free Software Foundation.

// Official game names, in the order a Chinese user expects them:
// Simplified Chinese, then Traditional Chinese, then English.
//
// Nothing here is scraped per title. Both Chinese catalogues are the same
// public metadata the Windows front-end uses (`blawar/titledb`), fetched once
// and reduced to a `title id -> name` table:
//
//   CN.zh.json  (~260 KB)   mainland eShop, Simplified names, ~109 titles
//   HK.zh.json  (~16 MB gz) Hong Kong eShop, Traditional names, ~22 600 titles
//
// HK.zh is the one that actually covers a normal retail library; CN.zh only
// has the small mainland catalogue, so Simplified wins when it exists and
// Traditional carries the rest. Both files list several products per title id
// (base game, base + expansion bundle, Switch 2 Edition …), so candidates are
// filtered down to the plainest name before being stored.

import Foundation

final class LocalizedTitleCatalog {

    static let shared = LocalizedTitleCatalog()

    private static let cnURL = "https://raw.githubusercontent.com/blawar/titledb/master/CN.zh.json"
    private static let hkURL = "https://raw.githubusercontent.com/blawar/titledb/master/HK.zh.json"

    /// A title can have a name in either Chinese script; nil means the
    /// catalogue had no entry for it.
    struct Name: Codable {
        var hans: String?
        var hant: String?
    }

    private let workQueue = DispatchQueue(label: "me.fratei.switchmtp.names", qos: .utility)
    private let directory: URL
    private let cacheFile: URL
    private let session: URLSession
    private var table: [String: Name]
    private var loadStarted = false

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwitchMTP Batch", isDirectory: true)
        directory = support.appendingPathComponent("Catalog", isDirectory: true)
        cacheFile = directory.appendingPathComponent("LocalizedNames.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 240
        configuration.httpAdditionalHeaders = ["User-Agent": "SwitchMTPBatch/1.4 (macOS)"]
        session = URLSession(configuration: configuration)

        if let data = try? Data(contentsOf: cacheFile),
           let decoded = try? JSONDecoder().decode([String: Name].self, from: data) {
            table = decoded
            loadStarted = true      // cache is authoritative for this launch
        } else {
            table = [:]
        }
    }

    // MARK: - Lookup

    /// Simplified first, then Traditional. English is a separate request
    /// (api.nlib.cc) because it is per-title and always available.
    func chineseName(for titleID: String) -> String? {
        guard let entry = table[titleID.uppercased()] else { return nil }
        if let hans = entry.hans, !hans.isEmpty { return hans }
        if let hant = entry.hant, !hant.isEmpty { return hant }
        return nil
    }

    /// What the list should show: the Simplified name when the mainland
    /// catalogue has it, otherwise the Traditional name converted to
    /// Simplified script locally. Nil when no catalogue knows the title.
    func preferredDisplayName(for titleID: String) -> String? {
        guard let entry = table[titleID.uppercased()] else { return nil }
        if let hans = entry.hans, !hans.isEmpty { return hans }
        if let hant = entry.hant, !hant.isEmpty {
            return ChineseScriptSimplifier.simplify(hant)
        }
        return nil
    }

    var isLoaded: Bool { !table.isEmpty }

    // MARK: - Loading

    /// Downloads and reduces both catalogues the first time it is needed.
    /// `progress` and `completion` run on the main queue; completion passes
    /// true when a table is available (cached or freshly built).
    func loadIfNeeded(progress: @escaping (String) -> Void,
                      completion: @escaping (Bool) -> Void) {
        if !table.isEmpty {
            completion(true)
            return
        }
        guard !loadStarted else {
            // A load is already in flight; the caller will be told again when
            // the table lands, so simply report the current state.
            completion(false)
            return
        }
        loadStarted = true
        DispatchQueue.main.async { progress("正在下载官方中文名称库（约 16 MB，只需一次）…") }

        workQueue.async { [weak self] in
            guard let self else { return }
            var merged: [String: Name] = [:]
            let group = DispatchGroup()

            group.enter()
            self.fetch(URL(string: Self.cnURL)!) { data in
                if let data { Self.merge(data, script: .hans, into: &merged) }
                group.leave()
            }
            group.enter()
            self.fetch(URL(string: Self.hkURL)!) { data in
                if let data { Self.merge(data, script: .hant, into: &merged) }
                group.leave()
            }
            group.wait()

            guard !merged.isEmpty else {
                DispatchQueue.main.async {
                    progress("中文名称库下载失败，先用英文名")
                    completion(false)
                }
                return
            }
            self.table = merged
            if let data = try? JSONEncoder().encode(merged) {
                try? data.write(to: self.cacheFile)
            }
            let count = merged.count
            DispatchQueue.main.async {
                progress("已载入 \(count) 个官方名称")
                completion(true)
            }
        }
    }

    private func fetch(_ url: URL, completion: @escaping (Data?) -> Void) {
        session.dataTask(with: url) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200, let data, data.count > 1024 {
                completion(data)
            } else {
                DebugLog.write("name catalogue: \(url.lastPathComponent) failed (status \(status), \(error?.localizedDescription ?? "no error"))")
                completion(nil)
            }
        }.resume()
    }

    // MARK: - Reduction

    private enum Script { case hans, hant }

    private static func merge(_ data: Data, script: Script, into table: inout [String: Name]) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for case let entry as [String: Any] in object.values {
            guard let rawID = entry["id"] as? String else { continue }
            let titleID = rawID.uppercased()
            guard PackageInspector.isValidTitleID(titleID),
                  let rawName = entry["name"] as? String else { continue }
            let name = clean(rawName)
            guard !name.isEmpty, isPlainName(name) else { continue }

            var existing = table[titleID] ?? Name()
            switch script {
            case .hans:
                if let old = existing.hans, old.count < name.count { continue }
                existing.hans = name
            case .hant:
                if let old = existing.hant, old.count < name.count { continue }
                existing.hant = name
            }
            table[titleID] = existing
        }
    }

    /// Bundles and re-releases share a title id with the base game; keep the
    /// plainest candidate, which is also the shortest one.
    private static func isPlainName(_ name: String) -> Bool {
        let noise = ["Nintendo Switch 2 Edition", "Switch 2 Edition", "組合", "组合",
                     "GP付与", "擴充票", "扩充票", "體驗版", "体验版", "DLC"]
        for token in noise where name.localizedCaseInsensitiveContains(token) { return false }
        return true
    }

    private static func clean(_ raw: String) -> String {
        var name = raw.replacingOccurrences(of: "™", with: "")
            .replacingOccurrences(of: "®", with: "")
            .replacingOccurrences(of: "©", with: "")
        name = name.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
