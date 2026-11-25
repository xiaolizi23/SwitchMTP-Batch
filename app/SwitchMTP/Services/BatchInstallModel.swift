// SwitchMTP Batch — a macOS MTP client for Nintendo Switch running DBI.
// Copyright (C) 2025 fratei
//
// This program is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License version 2 as published by
// the Free Software Foundation.

// The workspace model. Owns the scan, the plan, selection, and the hand-off to
// MTPManager's serial install queue.
//
// Two rules keep this honest:
//   1. Scanning never starts a transfer. Bytes only move after `commit(plan:)`,
//      which is called from the confirm sheet's "开始安装" button.
//   2. Nothing here reports "installed". The strongest claim is "已交给 DBI
//      ”， because DBI's MTP protocol has no way to tell the Mac what its own
//      installer concluded afterwards.

import Foundation
import AppKit
import Combine

/// Cheap cancellation flag shared between the main actor and a scan worker.
final class ScanToken {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}

final class BatchInstallModel: ObservableObject {

    // MARK: - Published state

    @Published private(set) var packages: [InstallPackage] = []
    @Published private(set) var groups: [InstallPackageGroup] = []
    @Published private(set) var isScanning = false
    @Published private(set) var scanHeadline = ""
    @Published private(set) var scannedFileCount = 0
    @Published private(set) var scannedBytes: Int64 = 0
    @Published private(set) var currentScanFolder = ""

    @Published var roots: [URL] = []
    @Published var filter: PlanFilter = .all
    @Published var sort: PlanSort = .title
    @Published var searchText = ""

    @Published private(set) var isDeepChecking = false
    @Published private(set) var deepCheckDone = 0
    @Published private(set) var deepCheckTotal = 0

    @Published var keySetPath: String? = nil {
        didSet { refreshKeySetState() }
    }
    @Published private(set) var keySetLoaded = false
    @Published private(set) var keySetError: String? = nil

    /// A `title.keys` sitting next to the chosen `prod.keys` is used when
    /// present. It is optional: the engine now recovers title keys from the
    /// package's own tickets, which is what DBI does, so this only helps for
    /// personalized tickets or older repacks.
    var titleKeysURL: URL? {
        guard let keySetPath else { return nil }
        let sibling = URL(fileURLWithPath: keySetPath)
            .deletingLastPathComponent()
            .appendingPathComponent("title.keys")
        return FileManager.default.isReadableFile(atPath: sibling.path) ? sibling : nil
    }

    /// A one-line result of the last action, shown as a banner in the sheet.
    @Published var banner: String? = nil
    @Published var bannerIsError = false

    @Published var targetKind: StorageKind = .sdInstall

    /// Cover art per base title ID. Filled asynchronously; the list falls back
    /// to an SF Symbol until an icon arrives, so a scan never waits on a
    /// network round trip.
    @Published private(set) var titleIcons: [String: NSImage] = [:]
    /// True while cover art / catalogue names are being fetched, so the toolbar
    /// can show a spinner instead of leaving the user guessing.
    @Published private(set) var isFetchingIcons = false
    /// Catalogue names, only consulted when the local folder name is useless.
    @Published private(set) var titleNames: [String: String] = [:]
    private var pendingIconIDs = Set<String>()
    private var pendingNameIDs = Set<String>()
    /// Titles already tried and found nothing for (no catalogue entry, offline).
    /// Kept so a rebuild does not hammer the network on every publish; the
    /// "刷新封面" button clears it for a manual retry.
    private var failedIconIDs = Set<String>()
    private var failedNameIDs = Set<String>()
    private var iconQueue: [String] = []
    private var iconInFlight = 0
    /// Four at a time: enough to fill a 40-title library quickly, low enough
    /// that a shared connection does not start dropping requests.
    private let maxIconConcurrency = 4

    /// Progress line for the one-off Chinese name catalogue download.
    @Published private(set) var catalogStatus: String? = nil
    private var catalogLoadInFlight = false
    private var catalogReady = LocalizedTitleCatalog.shared.isLoaded

    /// True while any group still shows a placeholder, which is when the
    /// "重新获取封面" button is worth its toolbar space.
    var hasMissingCovers: Bool {
        groups.contains { group in
            guard let titleID = group.baseTitleID else { return true }
            return titleIcons[titleID] == nil
        }
    }

    /// Set after a successful hand-off so the sheet can offer "回到队列".
    @Published private(set) var lastSubmittedCount = 0

    private let manager: MTPManager
    private var scanToken: ScanToken?
    private var scanGeneration = 0
    private var refreshScheduled = false

    private let recentRootsKey = "batchInstallRecentRoots"
    private let keySetPathKey = "batchInstallKeySetPath"

    init(manager: MTPManager) {
        self.manager = manager
        self.roots = (UserDefaults.standard.stringArray(forKey: recentRootsKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
        let stored = UserDefaults.standard.string(forKey: keySetPathKey)
        self.keySetPath = stored
        refreshKeySetState()
        // Restore the last target if it still exists on the connected device.
        if !manager.installTargets.contains(where: { $0.kind == targetKind }) {
            targetKind = manager.installTargets.first?.kind ?? .sdInstall
        }
    }

    // MARK: - Derived values

    var selectedPackages: [InstallPackage] { packages.filter(\.isSelected) }

    var selectedCount: Int { packages.filter(\.isSelected).count }

    var selectedBytes: Int64 { packages.reduce(0) { $0 + ($1.isSelected ? $1.fileSize : 0) } }

    var selectedSizeText: String { ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file) }

    var blockedSelectedCount: Int {
        packages.filter { $0.isSelected && $0.resolvedVerdict == .blocked }.count
    }

    var installTargets: [MTPStorage] { manager.installTargets }

    var targetStorage: MTPStorage? { installTargets.first { $0.kind == targetKind } }

    var isDeviceReady: Bool { targetStorage != nil }

    var canInstall: Bool {
        selectedCount > 0 && blockedSelectedCount == 0 && isDeviceReady && !isScanning && !isDeepChecking
    }

    var totalBytes: Int64 { packages.reduce(0) { $0 + $1.fileSize } }

    var totalSizeText: String { ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file) }

    /// The pool the deep pass acts on: the current selection, or everything
    /// when nothing is ticked.
    private func deepPool() -> [InstallPackage] {
        let pool = packages.filter { $0.isSelected }
        return pool.isEmpty ? packages : pool
    }

    var passedCount: Int { packages.filter { $0.resolvedVerdict == .passed }.count }
    var unverifiedCount: Int { packages.filter { $0.resolvedVerdict == .unverified }.count }
    var cautionCount: Int { packages.filter { $0.resolvedVerdict == .caution }.count }
    var blockedCount: Int { packages.filter { $0.resolvedVerdict == .blocked }.count }

    /// Selected files whose signatures were never confirmed. The confirm sheet
    /// uses this to warn that DBI may come back yellow.
    var selectedUnverifiedCount: Int {
        packages.filter { $0.isSelected && $0.resolvedVerdict == .unverified }.count
    }

    /// True only when the device reported a capacity we can trust. Virtual
    /// install targets report a meaningless size, so a "not enough space"
    /// verdict must not be invented from it.
    var spaceShortfall: Int64? {
        guard let storage = targetStorage, storage.sizeReliable, storage.freeSpace > 0,
              selectedBytes > 0, selectedBytes > storage.freeSpace else { return nil }
        return selectedBytes - storage.freeSpace
    }

    var visibleGroups: [InstallPackageGroup] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        var result: [InstallPackageGroup] = []

        for group in groups {
            var members = group.packages
            switch filter {
            case .all:
                break
            case .needsAttention:
                members = members.filter {
                    let verdict = $0.resolvedVerdict
                    return verdict == .caution || verdict == .blocked
                }
            case .onlyUpdatesAndDLC:
                members = members.filter { $0.contentType == .update || $0.contentType == .dlc }
            case .onlyBase:
                members = members.filter { $0.contentType == .base }
            }
            if !query.isEmpty {
                members = members.filter {
                    $0.displayName.lowercased().contains(query)
                    || ($0.titleID ?? "").lowercased().contains(query)
                    || $0.url.lastPathComponent.lowercased().contains(query)
                    || $0.url.deletingLastPathComponent().lastPathComponent.lowercased().contains(query)
                }
            }
            guard !members.isEmpty else { continue }
            var copy = group
            copy.packages = members
            result.append(copy)
        }

        switch sort {
        case .title:
            result.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size:
            result.sort { $0.totalSize > $1.totalSize }
        case .status:
            result.sort { $0.verdict.rank < $1.verdict.rank }
        case .path:
            result.sort { lhs, rhs in
                let l = lhs.packages.first?.url.path ?? ""
                let r = rhs.packages.first?.url.path ?? ""
                return l.localizedStandardCompare(r) == .orderedAscending
            }
        }
        return result
    }

    // MARK: - Importing

    /// Adds a folder or a set of files and starts a scan. Files and folders
    /// are both accepted: drag one game, ten games, or a whole library.
    func importURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        var newRoots: [URL] = []
        for url in urls {
            let standardized = url.standardizedFileURL
            guard !roots.contains(where: { $0.standardizedFileURL == standardized }) else { continue }
            newRoots.append(standardized)
        }
        if !newRoots.isEmpty {
            roots.append(contentsOf: newRoots)
            persistRoots()
        }
        startScan(urls: newRoots.isEmpty ? urls : newRoots)
    }

    func rescanAll() {
        startScan(urls: roots)
    }

    func removeRoot(_ url: URL) {
        roots.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        persistRoots()
    }

    func clearAll() {
        scanToken?.cancel()
        scanToken = nil
        packages = []
        groups = []
        titleIcons = [:]
        titleNames = [:]
        pendingIconIDs.removeAll()
        pendingNameIDs.removeAll()
        failedIconIDs.removeAll()
        failedNameIDs.removeAll()
        iconQueue.removeAll()
        isFetchingIcons = false
        catalogLoadInFlight = false
        catalogStatus = nil
        catalogReady = LocalizedTitleCatalog.shared.isLoaded
        scannedFileCount = 0
        scannedBytes = 0
        scanHeadline = ""
        roots = []
        persistRoots()
        banner = nil
    }

    private func persistRoots() {
        UserDefaults.standard.set(roots.map(\.path), forKey: recentRootsKey)
    }

    // MARK: - Scanning

    func startScan(urls: [URL]) {
        scanToken?.cancel()
        let token = ScanToken()
        scanToken = token
        scanGeneration += 1
        let generation = scanGeneration

        isScanning = true
        scanHeadline = "正在扫描…"
        currentScanFolder = ""
        banner = nil

        let existing = packages
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: [(URL, PackageFormat, Int64)] = []
            var seen = Set<String>(existing.map { $0.url.standardizedFileURL.path })
            var scannedDirs = 0

            func walk(_ url: URL) {
                guard !token.isCancelled else { return }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                if values?.isSymbolicLink == true { return }
                if values?.isDirectory == true {
                    scannedDirs += 1
                    if scannedDirs % 40 == 0 {
                        let folder = url.lastPathComponent
                        DispatchQueue.main.async { [weak self] in
                            guard let self, generation == self.scanGeneration else { return }
                            self.currentScanFolder = folder
                            self.scanHeadline = "正在扫描 \(scannedDirs) 个文件夹…已找到 \(found.count) 个安装包"
                        }
                    }
                    // Skip directories that can never contain installable
                    // packages but can hold tens of thousands of files.
                    let name = url.lastPathComponent.lowercased()
                    if name == ".git" || name == "node_modules" || name == "$recycle.bin"
                        || name == "system volume information" || name.hasSuffix(".app") {
                        return
                    }
                    if let contents = try? FileManager.default.contentsOfDirectory(
                        at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                        for child in contents {
                            if token.isCancelled { return }
                            walk(child)
                        }
                    }
                    return
                }
                guard values?.isRegularFile == true else { return }
                let name = url.lastPathComponent
                if name.hasPrefix(".") { return }
                guard let format = PackageFormat.from(url: url),
                      let size = values?.fileSize, size > 64 else { return }
                let key = url.standardizedFileURL.path
                guard !seen.contains(key) else { return }
                seen.insert(key)
                found.append((url, format, Int64(size)))
            }

            for root in urls {
                guard !token.isCancelled else { break }
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.scanGeneration else { return }
                    self.currentScanFolder = root.lastPathComponent
                }
                walk(root)
            }

            if token.isCancelled {
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.scanGeneration else { return }
                    self.isScanning = false
                    self.scanHeadline = "已取消扫描"
                }
                return
            }

            // Inspect and publish in batches so a 300-title library fills in
            // progressively instead of freezing the sheet until the end.
            var batch: [InstallPackage] = []
            for (index, item) in found.enumerated() {
                if token.isCancelled { break }
                var package = InstallPackage(url: item.0, format: item.1, fileSize: item.2,
                                             displayName: PackageInspector.displayName(for: item.0))
                let report = PackageInspector.inspect(url: item.0, format: item.1)
                package.report = report
                package.notes = report.issues
                package.quickVerdict = report.verdict
                package.titleID = report.titleID
                package.contentType = report.contentType
                package.version = report.version
                if let id = report.titleID, let value = UInt64(id, radix: 16) {
                    // Normalise to the application title ID: clear the patch
                    // bit and the add-on bit (bits 0-12). Clearing 16 bits
                    // would also erase part of the game identifier, e.g.
                    // 01000000000AA000 would turn into 0100152000020000.
                    package.baseTitleID = String(format: "%016llX", value & ~0x1FFF)
                }
                package.isSelected = report.verdict != .blocked
                batch.append(package)

                if batch.count >= 12 || index == found.count - 1 {
                    let toPublish = batch
                    batch.removeAll(keepingCapacity: true)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, generation == self.scanGeneration else { return }
                        self.merge(toPublish)
                    }
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.scanGeneration else { return }
                self.isScanning = false
                self.scanHeadline = self.packages.isEmpty
                    ? "没有找到可安装的 NSP / NSZ / XCI / XCZ 文件"
                    : "已就绪：\(self.packages.count) 个安装包，\(self.totalSizeText)"
                self.currentScanFolder = ""
                self.scanToken = nil
            }
        }
    }

    func cancelScan() {
        scanToken?.cancel()
    }

    private func merge(_ incoming: [InstallPackage]) {
        let existingPaths = Set(packages.map { $0.url.standardizedFileURL.path })
        let fresh = incoming.filter { !existingPaths.contains($0.url.standardizedFileURL.path) }
        guard !fresh.isEmpty else { return }
        packages.append(contentsOf: fresh)
        scannedFileCount = packages.count
        scannedBytes = totalBytes
        rebuildGroups()
        scheduleGroupRefresh()
    }

    /// Rebuilds the tree immediately; cheap for the sizes this workspace sees
    /// (tens to a few hundred files).
    private func rebuildGroups() {
        var byKey: [String: [InstallPackage]] = [:]
        for package in packages { byKey[package.groupKey, default: []].append(package) }

        groups = byKey.map { key, members in
            let sorted = members.sorted { lhs, rhs in
                if lhs.contentType.sortRank != rhs.contentType.sortRank {
                    return lhs.contentType.sortRank < rhs.contentType.sortRank
                }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
            let base = sorted.first { $0.contentType == .base } ?? sorted.first!
            // Official name first: Simplified, then the Traditional name
            // converted to Simplified script, then English; the local folder
            // name is only a fallback for titles the catalogues do not know.
            let titleID = base.baseTitleID
            let official = titleID.flatMap { id in
                LocalizedTitleCatalog.shared.preferredDisplayName(for: id) ?? titleNames[id]
            }
            let name = official ?? base.displayName
            return InstallPackageGroup(
                id: key,
                name: name,
                baseTitleID: base.baseTitleID,
                packages: sorted)
        }
        requestMissingIcons()
        if catalogReady {
            requestMissingNames()
        } else {
            startCatalogLoad()
        }
    }

    /// One-off download of the Chinese catalogues. Group names switch over as
    /// soon as the table lands, so the list shows folder names for a second or
    /// two and then settles on the official ones.
    private func startCatalogLoad() {
        guard !catalogLoadInFlight else { return }
        catalogLoadInFlight = true
        catalogStatus = "正在下载官方中文名称库（约 16 MB，只需一次）…"
        LocalizedTitleCatalog.shared.loadIfNeeded(progress: { [weak self] text in
            self?.catalogStatus = text
        }, completion: { [weak self] ok in
            guard let self else { return }
            self.catalogLoadInFlight = false
            self.catalogReady = true
            self.catalogStatus = nil
            if ok {
                self.rebuildGroups()
            } else {
                // No Chinese table: fall back to the English catalogue.
                self.rebuildGroups()
            }
        })
    }

    /// Kicks off cover art for any group that does not have one yet. The icon
    /// is *not* read out of the container (that needs prod.keys); it comes from
    /// the eShop catalogue by title ID, exactly like the Windows reference.
    ///
    /// Requests are paced instead of fired all at once: a 40-title library
    /// opened at once used to trip rate limits and leave rows permanently blank.
    private func requestMissingIcons() {
        var wanted: [String] = []
        for group in groups {
            guard let titleID = group.baseTitleID else { continue }
            if titleIcons[titleID] != nil { continue }
            if pendingIconIDs.contains(titleID) { continue }
            guard !failedIconIDs.contains(titleID) else { continue }
            if let cached = TitleIconStore.shared.cachedImage(for: titleID) {
                titleIcons[titleID] = cached
                continue
            }
            wanted.append(titleID)
        }
        for titleID in wanted where !pendingIconIDs.contains(titleID) {
            pendingIconIDs.insert(titleID)
            iconQueue.append(titleID)
        }
        pumpIconQueue()
        requestMissingNames()
    }

    private func pumpIconQueue() {
        while iconInFlight < maxIconConcurrency, !iconQueue.isEmpty {
            let titleID = iconQueue.removeFirst()
            iconInFlight += 1
            isFetchingIcons = true
            TitleIconStore.shared.fetchIcon(for: titleID) { [weak self] image in
                guard let self else { return }
                self.iconInFlight -= 1
                self.pendingIconIDs.remove(titleID)
                if let image {
                    self.titleIcons[titleID] = image
                } else {
                    self.failedIconIDs.insert(titleID)
                }
                self.pumpIconQueue()
                if self.iconInFlight == 0 {
                    self.isFetchingIcons = false
                }
            }
        }
    }

    /// English fallback, only for titles neither Chinese catalogue knows.
    /// Names arrive asynchronously and rebuild the list once.
    private func requestMissingNames() {
        guard catalogReady else { return }
        for group in groups {
            guard let titleID = group.baseTitleID else { continue }
            guard LocalizedTitleCatalog.shared.chineseName(for: titleID) == nil else { continue }
            guard titleNames[titleID] == nil,
                  !pendingNameIDs.contains(titleID),
                  !failedNameIDs.contains(titleID) else { continue }
            if let cached = TitleIconStore.shared.cachedName(for: titleID) {
                titleNames[titleID] = cached
                continue
            }
            pendingNameIDs.insert(titleID)
            TitleIconStore.shared.fetchName(for: titleID) { [weak self] name in
                guard let self else { return }
                self.pendingNameIDs.remove(titleID)
                guard let name else {
                    self.failedNameIDs.insert(titleID)
                    return
                }
                guard self.titleNames[titleID] != name else { return }
                self.titleNames[titleID] = name
                self.rebuildGroups()
            }
        }
    }

    /// Manual retry from the toolbar: forget every miss and ask again. Cached
    /// icons are still served from disk, so this only costs traffic for the
    /// rows that are actually blank.
    func refreshIcons() {
        failedIconIDs.removeAll()
        failedNameIDs.removeAll()
        requestMissingIcons()
        requestMissingNames()
    }

    private func scheduleGroupRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshScheduled = false
            self?.rebuildGroups()
        }
    }

    // MARK: - Selection

    func togglePackage(_ id: InstallPackage.ID) {
        guard let index = packages.firstIndex(where: { $0.id == id }) else { return }
        guard packages[index].isSelectable else {
            // 双保险：即便视图层漏判，阻止项也永远落不到勾选状态。
            updatePackage(id: id) { $0.isSelected = false }
            return
        }
        updatePackage(id: id) { $0.isSelected.toggle() }
    }

    func setGroupSelection(_ group: InstallPackageGroup, selected: Bool) {
        for member in group.packages where member.isSelectable {
            updatePackage(id: member.id) { $0.isSelected = selected }
        }
    }

    func setAllVisible(_ selected: Bool) {
        let visibleIDs = Set(visibleGroups.flatMap { $0.packages.map(\.id) })
        for index in packages.indices where visibleIDs.contains(packages[index].id) && packages[index].isSelectable {
            updatePackage(id: packages[index].id) { $0.isSelected = selected }
        }
    }

    func selectAllPassed() {
        for index in packages.indices {
            let shouldSelect = packages[index].isSelectable
            updatePackage(id: packages[index].id) { $0.isSelected = shouldSelect }
        }
    }

    func removePackages(in groupID: String) {
        packages.removeAll { $0.groupKey == groupID }
        rebuildGroups()
    }

    /// Mutates one package and mirrors the copy into every group snapshot that
    /// holds it. The list renders from `groups[].packages`; without this mirror
    /// a per-package update would stay invisible until the next `rebuildGroups()`,
    /// which is why rows used to freeze on the old state until the whole pass
    /// finished.
    private func updatePackage(id: InstallPackage.ID, _ mutate: (inout InstallPackage) -> Void) {
        guard let index = packages.firstIndex(where: { $0.id == id }) else { return }
        mutate(&packages[index])
        for gIndex in groups.indices {
            guard let mIndex = groups[gIndex].packages.firstIndex(where: { $0.id == id }) else { continue }
            groups[gIndex].packages[mIndex] = packages[index]
        }
    }

    // MARK: - Deep verification

    private func refreshKeySetState() {
        guard let path = keySetPath, FileManager.default.isReadableFile(atPath: path) else {
            keySetLoaded = false
            keySetError = keySetPath == nil ? nil : "文件不可读"
            return
        }
        do {
            let attributes = try KeySetStore.attributes(of: path)
            keySetLoaded = attributes.keyCount > 0
            keySetError = attributes.keyCount > 0 ? nil : "没有识别到任何 128 位密钥"
        } catch {
            keySetLoaded = false
            keySetError = "无法读取：\(error.localizedDescription)"
        }
    }

    func chooseKeySet() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择你从自己主机提取的 prod.keys。它只在本机读取，不会上传，也不会写进日志。"
        panel.prompt = "使用此密钥文件"
        if panel.runModal() == .OK, let url = panel.url {
            let changed = keySetPath != url.path
            keySetPath = url.path
            UserDefaults.standard.set(url.path, forKey: keySetPathKey)
            // Conclusions were derived under the old keyset; they cannot be
            // trusted against a different one, so drop the cached deep state.
            if changed { invalidateDeepResults() }
        }
    }

    func clearKeySet() {
        keySetPath = nil
        UserDefaults.standard.removeObject(forKey: keySetPathKey)
        invalidateDeepResults()
    }

    /// Drops every cached deep conclusion. Called when the keyset changes or
    /// is removed; structural (quick) verdicts are kept.
    private func invalidateDeepResults() {
        for index in packages.indices {
            packages[index].deepState = .notRun
            packages[index].deepProgress = 0
            packages[index].deepPhase = nil
            packages[index].deepNCAs = []
        }
        rebuildGroups()
    }

    /// Runs the optional deep pass over the current selection (or everything
    /// when nothing is selected). Only packages that have never been checked
    /// are verified, so adding a new folder does not force a second pass over
    /// titles already concluded. To re-check everything, clear the list and
    /// scan again, then press this button once more.
    func runDeepCheck() {
        guard !isDeepChecking, !isScanning else { return }
        guard let keyPath = keySetPath, keySetLoaded else {
            setBanner("请先选择有效的 prod.keys。没有密钥时只能做结构检查。", isError: true)
            return
        }
        guard DeepVerifier.hactoolURL != nil else {
            setBanner("应用内没有找到校验引擎（hactool）。请使用完整安装包。", isError: true)
            return
        }

        let targets = deepPool().filter { $0.deepState == .notRun }

        if targets.isEmpty {
            setBanner("所选项目都已深度检查过；清空列表重新扫描后可再跑一遍。", isError: false)
            return
        }

        performDeepChecks(on: targets.map { Self.deepJob($0, keyPath: keyPath) }) { [weak self] in
            guard let self else { return }
            self.setBanner(self.deepSummary(), isError: false)
        }
    }

    /// The gate behind the "开始安装" button. Anything the user selected but
    /// never deep-checked is verified first, so the plan's colours and the
    /// confirm sheet's risk acknowledgement describe real evidence instead of
    /// "结构看起来没问题". Without a keyset this degrades to a structural plan
    /// whose items stay `.unverified`.
    func preparePlan(completion: @escaping (InstallPlan?) -> Void) {
        guard canInstall else { completion(nil); return }

        let pending = selectedPackages.filter { $0.deepState == .notRun }
        guard !pending.isEmpty else { completion(makePlan()); return }

        guard let keyPath = keySetPath, keySetLoaded, DeepVerifier.hactoolURL != nil else {
            setBanner("没有可用的 prod.keys，本次只按结构判定；未验签项目会在确认页要求你勾选。", isError: false)
            completion(makePlan())
            return
        }

        performDeepChecks(on: pending.map { Self.deepJob($0, keyPath: keyPath) }) { [weak self] in
            guard let self else { return }
            self.setBanner(self.deepSummary(), isError: false)
            completion(self.makePlan())
        }
    }

    private typealias DeepJob = (id: InstallPackage.ID, url: URL, format: PackageFormat,
                                 keyPath: String, expectedNCAs: Int?,
                                 entrySizes: [String: Int64])

    private static func deepJob(_ package: InstallPackage, keyPath: String) -> DeepJob {
        let sizes = package.report?.entries.reduce(into: [String: Int64]()) { $0[$1.name] = $1.size } ?? [:]
        return (id: package.id, url: package.url, format: package.format, keyPath: keyPath,
                expectedNCAs: package.report?.ncaCount, entrySizes: sizes)
    }

    private func performDeepChecks(on jobs: [DeepJob], completion: @escaping () -> Void) {
        guard !jobs.isEmpty, !isDeepChecking else { completion(); return }
        guard let hactool = DeepVerifier.hactoolURL else { completion(); return }

        isDeepChecking = true
        deepCheckDone = 0
        deepCheckTotal = jobs.count
        let titleKeys = titleKeysURL
        // Freeze the work list: the scan may still publish new packages while
        // this runs, and those are simply not part of this pass.
        let frozen = jobs

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let keyset = try? KeySetStore.makeEphemeralCopy(of: frozen[0].keyPath)
            defer { if let keyset { KeySetStore.discard(keyset) } }

            for (offset, job) in frozen.enumerated() {
                DispatchQueue.main.async {
                    self.updatePackage(id: job.id) { package in
                        package.deepState = .running
                        package.deepProgress = 0
                        package.deepPhase = "准备中"
                    }
                }

                let result: DeepResult
                if let keyset {
                    result = DeepVerifier.verify(
                        url: job.url, format: job.format,
                        keysetURL: keyset,
                        titleKeysURL: titleKeys,
                        hactoolURL: hactool,
                        expectedNCAs: job.expectedNCAs,
                        entrySizes: job.entrySizes,
                        progress: { fraction, phase in
                            DispatchQueue.main.async { [weak self] in
                                guard let self else { return }
                                self.updatePackage(id: job.id) { package in
                                    package.deepProgress = min(max(fraction, 0), 1)
                                    package.deepPhase = phase
                                }
                            }
                        })
                } else {
                    result = DeepResult(state: .unavailable, notes: [
                        .init(severity: .warning, title: "密钥文件不可读", detail: "本次只完成结构检查。")
                    ], detail: "无法读取 prod.keys")
                }

                DispatchQueue.main.async {
                    self.updatePackage(id: job.id) { package in
                        package.deepState = result.state
                        package.deepNCAs = result.ncas
                        package.notes.append(contentsOf: result.notes)
                        // The colour is now derived from (quick, deep) together;
                        // mutating quickVerdict here used to hide a failed deep
                        // pass behind a stale "通过" label.
                        if result.state == .failed {
                            package.isSelected = false
                        }
                        package.deepProgress = 1
                        package.deepPhase = nil
                    }
                    self.deepCheckDone = offset + 1
                }
            }

            DispatchQueue.main.async {
                self.isDeepChecking = false
                self.rebuildGroups()
                completion()
            }
        }
    }

    private func deepSummary() -> String {
        let verified = packages.filter { $0.deepState == .verified }.count
        let signatureOnly = packages.filter { $0.deepState == .signatureOnly }.count
        let signature = packages.filter { $0.deepState == .signatureInvalid }.count
        let failed = packages.filter { $0.deepState == .failed }.count
        let unavailable = packages.filter { $0.deepState == .unavailable }.count
        return "深度检查完成：签名与哈希通过 \(verified)，签名通过/哈希未验 \(signatureOnly)，签名非官方 \(signature)，失败 \(failed)，无法验证 \(unavailable)"
    }

    // MARK: - Commit

    func makePlan() -> InstallPlan? {
        guard canInstall else { return nil }
        // Keep each title's files together and inside each title send base,
        // then update, then add-ons. See `InstallPlanOrder` for why one pass of
        // mixed comparators was not good enough.
        var titles: [String: String] = [:]
        for group in groups { titles[group.id] = group.name }
        let selected = InstallPlanOrder.ordered(selectedPackages, groupTitles: titles)
        return InstallPlan(packages: selected, targetKind: targetKind, generatedAt: Date())
    }

    /// Hands the plan to DBI through the existing serial queue. Called only
    /// after the confirm sheet's explicit button.
    func commit(plan: InstallPlan) {
        guard let storage = installTargets.first(where: { $0.kind == plan.targetKind }) else {
            setBanner("目标存储已不可用，请重新连接主机。", isError: true)
            return
        }
        let outcome = manager.install(fileURLs: plan.packages.map(\.url), to: storage)
        if outcome.isError {
            setBanner(outcome.message, isError: true)
            return
        }
        lastSubmittedCount = plan.packages.count
        setBanner("已把 \(plan.packages.count) 个项目（\(plan.totalSizeText)）交给 DBI，正在按顺序发送。安装进度请看 Switch 屏幕。", isError: false)
        // The delivered items stay in the workspace as "submitted" instead of
        // vanishing: during a two-hour run the list is the only place that
        // still says what this batch was made of. They are deselected so a
        // second Send cannot resend them.
        let ids = Set(plan.packages.map(\.id))
        for index in packages.indices where ids.contains(packages[index].id) {
            packages[index].isSubmitted = true
            packages[index].isSelected = false
        }
        rebuildGroups()
    }

    /// Forgets the "submitted" marks, so a title can be sent again (a re-install
    /// after a failure, or a fresh run of the same folder).
    func clearSubmittedMarks() {
        for index in packages.indices { packages[index].isSubmitted = false }
        rebuildGroups()
    }

    var submittedCount: Int { packages.filter(\.isSubmitted).count }
    var remainingCount: Int { packages.filter { !$0.isSubmitted }.count }

    // MARK: - NSZ unpacking

    /// Converts one NSZ to NSP at a user-chosen path. Runs off the main thread
    /// because a big title takes tens of seconds; the banner carries progress
    /// and the final CNMT hash summary.
    func unpack(_ package: InstallPackage, to destination: URL) {
        guard package.format == .nsz else {
            setBanner("只有 NSZ 需要解包；这个文件是 \(package.format.displayName)。", isError: true)
            return
        }
        guard let tool = NSZUnpacker.toolURL else {
            setBanner("应用包内缺少 nszunpack，无法解包。请用完整的发布包或重新构建。", isError: true)
            return
        }
        let source = package.url
        let name = package.displayName
        setBanner("正在解包 \(name)（zstd 解压 + 按 section 重加密）…", isError: false)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let conversion = try NSZUnpacker.unpack(url: source, to: destination, tool: tool)
                let size = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? NSNumber
                let sizeText = size.map { ByteCountFormatter.string(fromByteCount: $0.int64Value, countStyle: .file) } ?? "NSP"
                DispatchQueue.main.async {
                    self?.setBanner("已解包：\(destination.path)（\(sizeText)，用时 \(String(format: "%.1f", conversion.duration)) 秒）。\(conversion.summaryText)。",
                                    isError: conversion.mismatchedCount > 0)
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                DispatchQueue.main.async {
                    self?.setBanner("解包失败：\(message)", isError: true)
                }
            }
        }
    }

    func setBanner(_ text: String, isError: Bool) {
        banner = text
        bannerIsError = isError
    }
}
