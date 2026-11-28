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

    /// Paths the user dropped from the plan by hand. A rescan must not bring
    /// them back, otherwise "remove this row" would only last until the next
    /// refresh; re-importing the same folder explicitly clears it again
    /// (`importURLs`), which is the undo path.
    private var excludedPaths: Set<String> = []

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

    /// Selected files flagged for the applet/title-mode environment advisory.
    /// Independent of the signature/structure verdict; the confirm sheet asks
    /// for a separate acknowledgement when this is non-zero.
    var selectedAdvisoryCount: Int {
        packages.filter { $0.isSelected && $0.needsTitleModeAdvisory }.count
    }

    // MARK: - Install queue bridge

    /// Soft-pause state mirrored from the manager's serial queue.
    var queuePaused: Bool { manager.queuePaused }

    var pendingInstallCount: Int { manager.pendingInstallCount }

    func setQueuePaused(_ paused: Bool) { manager.setQueuePaused(paused) }

    /// The live queue entry matching a plan row, so the row can render its own
    /// progress bar, speed and failure hint. Matched by standardized path; the
    /// queue item's URL is the same file handed off at commit time.
    func queueItem(for package: InstallPackage) -> InstallQueueItem? {
        let path = package.url.standardizedFileURL.path
        return manager.installQueue.first { $0.url.standardizedFileURL.path == path }
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
            // Picking the folder again is the explicit "put it back" gesture:
            // rows removed by right-click become visible to this scan again.
            clearExclusions(under: standardized)
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

    /// Forgets every exclusion at or below `url`. Only an explicit import
    /// clears exclusions; `rescanAll` deliberately keeps them.
    private func clearExclusions(under url: URL) {
        let base = url.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        excludedPaths = excludedPaths.filter { $0 != base && !$0.hasPrefix(prefix) }
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
        excludedPaths.removeAll()
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
        let excluded = excludedPaths
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let existingPaths = Set(existing.map { $0.url.standardizedFileURL.path })
            let found = BatchScanner.scan(
                urls: urls,
                existingPaths: existingPaths,
                excludedPaths: excluded,
                shouldCancel: { token.isCancelled }) { count, folder in
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.scanGeneration else { return }
                    self.currentScanFolder = folder
                    self.scanHeadline = "正在扫描…已找到 \(count) 个安装包"
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.scanGeneration else { return }
                if token.isCancelled {
                    self.isScanning = false
                    self.scanHeadline = "已取消扫描"
                    self.scanToken = nil
                    return
                }
                self.merge(found)
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
        // Group titles keep the Chinese-first order: Simplified, then the
        // Traditional name converted to Simplified, then English. The local
        // file name is the last resort. Package rows stay English so a row
        // never mixes scripts.
        var officialNames: [String: String] = [:]
        for package in packages {
            guard let id = package.baseTitleID else { continue }
            if let name = LocalizedTitleCatalog.shared.preferredDisplayName(for: id) ?? titleNames[id] {
                officialNames[id] = name
            }
        }
        groups = BatchGrouper.group(packages, officialNames: officialNames)
        requestMissingIcons()
        requestMissingNames()
        if !catalogReady {
            startCatalogLoad()
        }
    }

    /// One-off download of the Chinese catalogues. Group names switch over as
    /// soon as the table lands, so the list shows file names for a second or
    /// two and then settles on the official Chinese ones.
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
            self.rebuildGroups()
        })
    }

    /// The English title a package row shows. Group rows keep the Chinese name;
    /// rows stay English so a single row never mixes scripts. Base games keep
    /// the plain title, a patch adds `-update`, add-ons add `-dlc1`, `-dlc2`.
    func displayTitle(for package: InstallPackage) -> String {
        guard let group = groups.first(where: { $0.id == package.groupKey }) else {
            return package.displayName
        }
        let baseName = englishName(for: group)
        switch package.contentType {
        case .base, .unknown:
            return baseName
        case .update:
            let updates = group.packages.filter { $0.contentType == .update }
            guard updates.count > 1,
                  let index = updates.firstIndex(where: { $0.id == package.id }) else {
                return "\(baseName)-update"
            }
            return "\(baseName)-update\(index + 1)"
        case .dlc:
            let addOns = group.packages.filter { $0.contentType == .dlc }
            let index = addOns.firstIndex(where: { $0.id == package.id }) ?? 0
            return "\(baseName)-dlc\(index + 1)"
        }
    }

    /// Catalogue English title for a group, used by the package rows; falls
    /// back to the group name when the English catalogue does not know it.
    private func englishName(for group: InstallPackageGroup) -> String {
        guard let titleID = group.baseTitleID, let name = titleNames[titleID] else {
            return group.name
        }
        return name
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

    /// English catalogue title for every group that still lacks one. Names
    /// arrive asynchronously and rebuild the list once each; the local file
    /// name stays in place until then.
    private func requestMissingNames() {
        for group in groups {
            guard let titleID = group.baseTitleID else { continue }
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

    // MARK: - Removing rows

    /// Drops one package from the plan. The file on disk is not touched; its
    /// path is excluded so a later rescan cannot bring the row back — that is
    /// what makes "remove" mean the same thing here as it does in Finder.
    /// Picking the folder again is the undo (`importURLs`).
    func removePackage(_ id: InstallPackage.ID) {
        guard let index = packages.firstIndex(where: { $0.id == id }) else { return }
        let gone = packages[index]
        let name = displayTitle(for: gone)
        excludedPaths.insert(gone.url.standardizedFileURL.path)
        packages.remove(at: index)
        finishRemoval(count: 1, name: name)
    }

    /// Drops every member of a group — base, updates and add-ons — because the
    /// game is the unit the row represents, even when a filter or a search is
    /// only showing part of it on screen.
    func removePackages(in groupID: String) {
        let gone = packages.filter { $0.groupKey == groupID }
        guard !gone.isEmpty else { return }
        let name = groups.first(where: { $0.id == groupID })?.name ?? gone[0].displayName
        for package in gone {
            excludedPaths.insert(package.url.standardizedFileURL.path)
        }
        packages.removeAll { $0.groupKey == groupID }
        finishRemoval(count: gone.count, name: name)
    }

    private func finishRemoval(count: Int, name: String) {
        scannedFileCount = packages.count
        scannedBytes = totalBytes
        rebuildGroups()
        bannerIsError = false
        banner = count == 1
            ? "已从清单移除「\(name)」，硬盘文件没有改动。重新扫描不会把它加回来；重新选择该文件夹可恢复。"
            : "已从清单移除「\(name)」共 \(count) 项，硬盘文件没有改动。重新扫描不会把它们加回来；重新选择该文件夹可恢复。"
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

        performDeepChecks(keysetPath: keyPath, jobs: DeepCheckRunner.jobs(for: targets)) { [weak self] in
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

        performDeepChecks(keysetPath: keyPath, jobs: DeepCheckRunner.jobs(for: pending)) { [weak self] in
            guard let self else { return }
            self.setBanner(self.deepSummary(), isError: false)
            completion(self.makePlan())
        }
    }

    private func performDeepChecks(keysetPath: String,
                                   jobs: [DeepCheckRunner.Job],
                                   completion: @escaping () -> Void) {
        guard !jobs.isEmpty, !isDeepChecking else { completion(); return }
        guard let hactool = DeepVerifier.hactoolURL else { completion(); return }

        isDeepChecking = true
        deepCheckDone = 0
        deepCheckTotal = jobs.count
        // Mark every queued job as running up front so each row shows its live
        // progress bar and percentage as soon as the pass starts. The state used
        // to stay `.notRun` until the result arrived, which hid the in-flight
        // bar (its visibility gate is `deepState != .notRun`) entirely.
        for job in jobs {
            updatePackage(id: job.id) { package in
                package.deepState = .running
                package.deepProgress = 0
                package.deepPhase = "准备中"
            }
        }
        let titleKeys = DeepCheckRunner.titleKeysURL(for: keysetPath)
        // Freeze the work list: the scan may still publish new packages while
        // this runs, and those are simply not part of this pass.
        let frozen = jobs

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let keyset = try? KeySetStore.makeEphemeralCopy(of: keysetPath)
            defer { if let keyset { KeySetStore.discard(keyset) } }

            DeepCheckRunner.run(
                jobs: frozen,
                keysetURL: keyset,
                titleKeysURL: titleKeys,
                hactoolURL: hactool,
                onProgress: { job, fraction, phase in
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.updatePackage(id: job.id) { package in
                            package.deepProgress = min(max(fraction, 0), 1)
                            package.deepPhase = phase
                        }
                    }
                },
                onResult: { job, result in
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
                        self.deepCheckDone += 1
                    }
                })

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
