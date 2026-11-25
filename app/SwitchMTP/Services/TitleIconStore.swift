// SwitchMTP Batch — a macOS MTP client for Nintendo Switch running DBI.
// Copyright (C) 2026 fratei
//
// This program is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License version 2 as published by
// the Free Software Foundation.

// Cover art for title groups.
//
// Where the icon comes from is worth stating plainly, because it is *not*
// inside the drop: retail NSP/XCI files keep the 256×256 JPEG in the control
// NCA's NACP, and reading it would mean decrypting that NCA with prod.keys and
// walking its romfs. The Windows front-end this workspace was modelled on does
// not do that either — it downloads the icon by title ID and caches it.
//
// That front-end pulls a 90 MB titledb index first. That is a bad trade here:
// the download is slow on a Chinese connection and the whole catalogue is
// fetched for the handful of files actually dropped. Instead this asks the
// community catalogue at api.nlib.cc for `…/nx/<title id>/icon/256`, which
// returns the same eShop artwork as a ~40 KB JPEG in one round trip.
//
// Everything is keyed by title ID, never by name, so a Chinese folder name and
// an English catalogue entry can never collide. Results are cached under
// Application Support, so a title costs one request ever — which is also what
// keeps covers stable across launches when the network is flaky.

import AppKit
import Foundation

final class TitleIconStore {

    static let shared = TitleIconStore()

    /// Same artwork as Nintendo's own eShop CDN; keyed by title ID so there is
    /// no name matching to get wrong. Size is rounded by the service to the
    /// nearest 10 px, which is why a 256 request comes back 260×260.
    private static let endpoint = "https://api.nlib.cc/nx/"
    private static let iconSize = 256

    private let session: URLSession
    private let workQueue = DispatchQueue(label: "me.fratei.switchmtp.icons", qos: .utility)
    private let catalogQueue = DispatchQueue(label: "me.fratei.switchmtp.catalog", qos: .utility)
    private let iconDirectory: URL
    private let nameFile: URL
    private var names: [String: String]

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwitchMTP Batch", isDirectory: true)
        iconDirectory = support.appendingPathComponent("GameIcons", isDirectory: true)
        nameFile = support.appendingPathComponent("CatalogNames.json")
        try? FileManager.default.createDirectory(at: iconDirectory, withIntermediateDirectories: true)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.httpAdditionalHeaders = [
            "User-Agent": "SwitchMTPBatch/1.3 (macOS)",
            "Accept": "application/json, image/*"
        ]
        session = URLSession(configuration: configuration)

        if let data = try? Data(contentsOf: nameFile),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            names = decoded
        } else {
            names = [:]
        }
    }

    // MARK: - Icons

    /// Disk hit only: safe to call synchronously while a list is being built.
    func cachedImage(for titleID: String) -> NSImage? {
        let url = iconDirectory.appendingPathComponent(Self.fileName(for: titleID))
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return nil }
        return image
    }

    /// Loads the cached icon or, when it is missing, fetches it in the
    /// background. `completion` always runs on the main queue and receives nil
    /// when the title has no catalogue entry or the network is unavailable.
    func fetchIcon(for titleID: String, completion: @escaping (NSImage?) -> Void) {
        if let cached = cachedImage(for: titleID) {
            completion(cached)
            return
        }
        let id = titleID.uppercased()
        guard let url = URL(string: "\(Self.endpoint)\(id)/icon/\(Self.iconSize)") else {
            completion(nil)
            return
        }
        request(url, id: id, kind: "icon", attemptsLeft: 2) { [weak self] data in
            guard let self, let data, let image = NSImage(data: data) else { return nil }
            try? data.write(to: self.iconDirectory.appendingPathComponent(Self.fileName(for: id)))
            return image
        } completion: { image in
            completion(image)
        }
    }

    // MARK: - Names

    /// Catalogue name for a title ID, if one was already fetched.
    func cachedName(for titleID: String) -> String? {
        catalogQueue.sync { names[titleID.uppercased()] }
    }

    /// English/romaji catalogue name. Only used to label a group whose local
    /// folder name says nothing (`升级档-v1.1.0`, `nsz本体`); a real Chinese
    /// folder name always wins over this.
    func fetchName(for titleID: String, completion: @escaping (String?) -> Void) {
        let id = titleID.uppercased()
        if let cached = cachedName(for: id) {
            completion(cached)
            return
        }
        guard let url = URL(string: "\(Self.endpoint)\(id)?fields=name") else {
            completion(nil)
            return
        }
        request(url, id: id, kind: "name", attemptsLeft: 2) { data -> String? in
            guard let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return nil }
            // Catalogue names carry trademark marks, e.g. "Super Mario Bros.™
            // Wonder"; they are noise in a list row.
            name = name.replacingOccurrences(of: "™", with: "")
            name = name.replacingOccurrences(of: "®", with: "")
            name = name.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        } completion: { [weak self] name in
            guard let self, let name else { completion(nil); return }
            self.catalogQueue.async {
                self.names[id] = name
                if let data = try? JSONEncoder().encode(self.names) {
                    try? data.write(to: self.nameFile)
                }
            }
            completion(name)
        }
    }

    // MARK: - Plumbing

    /// One request, retried once on transport errors, 429 and 5xx. A 404 is
    /// permanent (the catalogue simply has no entry) and is not retried.
    private func request<T>(_ url: URL, id: String, kind: String, attemptsLeft: Int,
                            parse: @escaping (Data?) -> T?,
                            completion: @escaping (T?) -> Void) {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.session.dataTask(with: url) { data, response, error in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200, let value = parse(data) {
                    DispatchQueue.main.async { completion(value) }
                    return
                }
                let retryable = error != nil || (500...599).contains(status) || status == 429
                if retryable, attemptsLeft > 1 {
                    self.workQueue.asyncAfter(deadline: .now() + 1.5) {
                        self.request(url, id: id, kind: kind, attemptsLeft: attemptsLeft - 1,
                                     parse: parse, completion: completion)
                    }
                    return
                }
                DebugLog.write("title \(kind)s: none for \(id) (status \(status), \(error?.localizedDescription ?? "no error"))")
                DispatchQueue.main.async { completion(nil) }
            }.resume()
        }
    }

    private static func fileName(for titleID: String) -> String {
        let digits = titleID.uppercased().filter(\.isHexDigit)
        return (digits.isEmpty ? "unknown" : digits) + ".jpg"
    }
}
