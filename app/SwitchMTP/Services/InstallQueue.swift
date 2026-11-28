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

import Foundation

/// One title waiting to be installed on the console.
struct InstallQueueItem: Identifiable, Equatable {
    enum State: Equatable {
        case waiting
        case active
        /// The bytes are on the console; DBI is committing them.
        case sent
        case failed(String)
        case cancelled

        var isFinished: Bool {
            switch self {
            case .waiting, .active: return false
            case .sent, .failed, .cancelled: return true
            }
        }
    }

    let id = UUID()
    let url: URL
    let storage: MTPStorage
    var state: State = .waiting
    /// How many uploads this file has already had. A failed upload is re-queued
    /// until `maxInstallAttempts` is reached, so a cable hiccup or a DBI session
    /// that needed resetting costs a retry instead of the rest of the batch.
    var attempts: Int = 0
    var lastError: String?
    /// Actionable remediation attached by the backend to a failure (e.g. the
    /// applet/title-mode hint). Shown beneath the localized error when present.
    var hint: String?

    // MARK: - Live transfer progress

    /// 0...1 for the active upload; 1 once the bytes are on the console.
    /// Derived from real backend payloads, never invented.
    var progress: Double = 0
    var sentBytes: Int64?
    var totalBytes: Int64?
    /// MiB/s as reported by the backend (same conversion as `TransferStatistics.speed`).
    var speedMBps: Double?
    /// Raw `TransferPhase` value, kept so the row can show the console-committing
    /// indeterminate state without re-decoding.
    var phaseRaw: String?

    var name: String { url.lastPathComponent }

    /// File size on disk, or nil when it cannot be read.
    var byteSize: Int64? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return (values?.fileSize).map(Int64.init)
    }
}

extension MTPManager {

    /// How many uploads one file gets before it is written off. The first
    /// attempt is the normal one; the two after it cover a dropped USB
    /// connection and a DBI session that had to be reset.
    static let maxInstallAttempts = 3

    // MARK: - Persistence

    /// Where the pending queue lives between launches. Only the files still to
    /// be sent are stored, so a finished run leaves nothing behind.
    static var installQueueStoreURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("SwitchMTP Batch", isDirectory: true)
            .appendingPathComponent("InstallQueue.json")
    }

    /// Writes every item that is still waiting (including the active one, which
    /// is stored as waiting so a crash mid-transfer resumes that file).
    func persistInstallQueue() {
        let pending = installQueue.filter { !$0.state.isFinished }
        let entries = pending.map {
            InstallQueueStore.Entry(path: $0.url.path,
                                    storageKind: $0.storage.kind.rawValue,
                                    attempts: $0.attempts)
        }
        InstallQueueStore.save(entries, to: Self.installQueueStoreURL, paused: queuePaused)
    }

    /// Restores the queue saved by the previous run. Called once at startup;
    /// nothing is sent until the console is connected again, at which point the
    /// normal drain picks the list up from the first unsent item. A persisted
    /// soft-pause stays parked until the user presses continue.
    func restorePersistedInstallQueue() {
        guard installQueue.isEmpty else { return }
        let document = InstallQueueStore.loadDocument(from: Self.installQueueStoreURL)
        let stored = document.entries
        guard !stored.isEmpty else { return }

        var restored: [InstallQueueItem] = []
        var dropped: [String] = []
        for entry in stored {
            let fileURL = URL(fileURLWithPath: entry.path)
            guard FileManager.default.isReadableFile(atPath: entry.path),
                  MTPManager.installableExtensions.contains(fileURL.pathExtension.lowercased()) else {
                dropped.append(fileURL.lastPathComponent)
                continue
            }
            let kind = StorageKind(rawValue: entry.storageKind)
            // The real storage is rebuilt on connect and re-resolved by kind,
            // so the placeholder only carries what the queue needs meanwhile.
            var storage = MTPStorage(id: "restored-\(entry.storageKind)",
                                     name: kind?.rawValue ?? entry.storageKind,
                                     freeSpace: 0, totalSpace: 0)
            storage.kind = kind ?? .sdInstall
            var item = InstallQueueItem(url: fileURL, storage: storage)
            item.attempts = min(entry.attempts, Self.maxInstallAttempts)
            restored.append(item)
        }

        installQueue = restored
        queuePaused = document.paused
        if !restored.isEmpty {
            DebugLog.write("install queue: restored \(restored.count) item(s) from disk, paused=\(queuePaused)")
            if queuePaused {
                queueNotice = String(localized: "已暂停：\(restored.count) 个安装项保留在队列中，连接主机后点击「继续」再发送。")
            } else {
                queueNotice = String(localized: "已恢复上次未完成的 \(restored.count) 个安装项，连接主机后自动继续。")
                scheduleInstallQueueDrain()
            }
        }
        if !dropped.isEmpty {
            DebugLog.write("install queue: dropped missing files \(dropped.joined(separator: ", "))")
        }
        persistInstallQueue()
    }

    // MARK: - Public API

    /// Adds files to the install queue, starting the first one if idle.
    ///
    /// Appending rather than rejecting is the whole point: a user who has ten
    /// titles to install should be able to drop all ten and walk away, and
    /// dropping an eleventh mid-transfer should extend the queue rather than
    /// fail with "another transfer is already running".
    @discardableResult
    func enqueueInstall(fileURLs: [URL], to storage: MTPStorage) -> WorkflowOutcome {
        let rejected = fileURLs.filter {
            !MTPManager.installableExtensions.contains($0.pathExtension.lowercased())
        }
        let accepted = fileURLs.filter {
            MTPManager.installableExtensions.contains($0.pathExtension.lowercased())
        }

        guard !accepted.isEmpty else {
            if rejected.isEmpty {
                return .unavailable(String(localized: "No files to install."))
            }
            let names = rejected.map(\.lastPathComponent).joined(separator: ", ")
            return .unavailable(String(localized: "Only .nsp, .nsz, .xci and .xcz files can be installed. Skipped: \(names)"))
        }

        // Don't queue the same file twice while it is still pending.
        let pending = Set(installQueue.filter { !$0.state.isFinished }.map(\.url))
        let fresh = accepted.filter { !pending.contains($0) }
        let duplicates = accepted.count - fresh.count

        guard !fresh.isEmpty else {
            return .unavailable(String(localized: "Those files are already queued."))
        }

        installQueue.append(contentsOf: fresh.map { InstallQueueItem(url: $0, storage: storage) })
        persistInstallQueue()

        let started = startNextQueuedInstallIfIdle()
        if !started { scheduleInstallQueueDrain() }

        var message: String
        let waiting = installQueue.filter { $0.state == .waiting }.count
        if started && waiting == 0 {
            message = String(localized: "Installing \(fresh[0].lastPathComponent). Progress is shown on the console.")
        } else if started {
            message = String(localized: "Installing \(fresh[0].lastPathComponent); \(waiting) more queued.")
        } else {
            message = String(localized: "Queued \(fresh.count) file(s) for \(storage.name). They will install one after another.")
        }
        if !rejected.isEmpty {
            let names = rejected.map(\.lastPathComponent).joined(separator: ", ")
            message += " " + String(localized: "Skipped (not installable): \(names)")
        }
        if duplicates > 0 {
            message += " " + String(localized: "\(duplicates) already queued.")
        }
        return .started(message)
    }

    /// Removes a queued item. The item currently uploading is cancelled instead.
    func removeFromInstallQueue(_ id: UUID) {
        guard let index = installQueue.firstIndex(where: { $0.id == id }) else { return }
        if installQueue[index].state == .active {
            cancelTransfer()
            return
        }
        installQueue.remove(at: index)
        persistInstallQueue()
    }

    /// Drops everything not yet started. The active upload keeps running; use
    /// Cancel for that, so a half-written title is never left implicit.
    func clearPendingInstalls() {
        installQueue.removeAll { $0.state == .waiting }
        persistInstallQueue()
    }

    /// Forgets finished entries so the list does not grow without bound.
    func clearFinishedInstalls() {
        installQueue.removeAll { $0.state.isFinished }
        persistInstallQueue()
    }

    /// Items still to be sent, including the one in flight.
    var pendingInstallCount: Int {
        installQueue.filter { !$0.state.isFinished }.count
    }

    var hasQueuedInstalls: Bool { pendingInstallCount > 0 }

    // MARK: - Soft pause

    /// Soft pause: the upload currently in flight keeps running to its finish,
    /// but no waiting item is dispatched next. Parked items stay queued;
    /// resuming re-arms the drain. The flag is persisted so a restart leaves
    /// the batch parked until the user presses continue.
    func setQueuePaused(_ paused: Bool) {
        guard queuePaused != paused else { return }
        queuePaused = paused
        persistInstallQueue()
        if paused {
            queueNotice = String(localized: "已暂停：当前项目传完后不再发送下一个。")
            DebugLog.write("install queue paused by user")
        } else {
            queueNotice = nil
            DebugLog.write("install queue resumed by user")
            scheduleInstallQueueDrain()
        }
    }

    /// Mirrors the active upload's live byte counters onto its queue item, so
    /// the plan rows and the queue list can render per-title progress from one
    /// source. Called from the progress callback; a no-op when the running
    /// transfer is not a queued install.
    func syncActiveInstallProgress(stats: TransferStatistics) {
        guard let id = activeInstallItemID,
              let index = installQueue.firstIndex(where: { $0.id == id }) else { return }
        installQueue[index].progress = stats.progressPercentage
        installQueue[index].sentBytes = stats.progressData.bulkFileSize?.sent
        installQueue[index].totalBytes = stats.progressData.bulkFileSize?.total
        installQueue[index].speedMBps = stats.speed
        installQueue[index].phaseRaw = stats.phase.rawValue
    }

    // MARK: - Queue draining

    /// Asks the queue to start its next item as soon as the device is free.
    ///
    /// The device is *not* free the instant a transfer's done callback fires:
    /// the app immediately reloads the current directory, and starting an
    /// upload while that walk is in flight would route the walk's callbacks
    /// into the upload handler. So this retries until the state machine is
    /// genuinely idle rather than assuming it already is.
    ///
    /// The retry runs for the whole of an active install, which across a 25 GB
    /// queue measured ~2,200 wake-ups. That was tempting to back off, but the
    /// `installQueueDrainScheduled` guard means a pending slow retry *swallows*
    /// the fast re-arm `finishActiveInstall` posts when a transfer ends -- so
    /// backing off to, say, five seconds buys nothing and inserts up to five
    /// seconds of dead air between every title. The wake-ups are a trivial
    /// main-queue block each and measured no CPU; the polling stays.
    func scheduleInstallQueueDrain(after delay: TimeInterval = 0.35) {
        // Soft pause holds the queue parked; resuming re-arms the drain from
        // the continue button instead.
        guard !queuePaused else { return }
        guard !installQueueDrainScheduled else { return }
        guard installQueue.contains(where: { $0.state == .waiting }) else { return }
        installQueueDrainScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.installQueueDrainScheduled = false
            guard self.installQueue.contains(where: { $0.state == .waiting }) else { return }
            if !self.startNextQueuedInstallIfIdle() {
                // Still busy, or disconnected. Keep asking; a queued install
                // that silently never starts is worse than a slow one.
                if self.connectionState.isConnected {
                    self.scheduleInstallQueueDrain()
                }
            }
        }
    }

    /// Starts the next waiting item when nothing else is using the device.
    ///
    /// Returns true when an upload was dispatched.
    @discardableResult
    func startNextQueuedInstallIfIdle() -> Bool {
        guard isDeviceIdle, activeInstallItemID == nil else {
            // Deferring because an install is in flight is the normal case and
            // says nothing; only the unexplained kind is worth a line.
            if activeInstallItemID == nil {
                DebugLog.write("queue drain deferred: device busy (op not idle)")
            }
            return false
        }
        guard connectionState.isConnected else {
            DebugLog.write("queue drain deferred: not connected")
            return false
        }
        guard !queuePaused else {
            DebugLog.write("queue drain deferred: paused")
            return false
        }
        guard let index = installQueue.firstIndex(where: { $0.state == .waiting }) else { return false }

        let item = installQueue[index]
        // The storage list is rebuilt on every reconnect, so resolve by kind
        // rather than trusting a handle captured when the file was dropped.
        guard let storage = connectionState.device?.storages.first(where: { $0.id == item.storage.id })
                ?? storage(ofKind: item.storage.kind) else {
            installQueue[index].state = .failed(String(localized: "That install storage is no longer available. Reconnect the console and try again."))
            persistInstallQueue()
            return false
        }

        installQueue[index].state = .active
        installQueue[index].attempts += 1
        installQueue[index].progress = 0
        installQueue[index].sentBytes = nil
        installQueue[index].totalBytes = nil
        installQueue[index].speedMBps = nil
        installQueue[index].phaseRaw = nil
        installQueue[index].hint = nil
        activeInstallItemID = item.id
        persistInstallQueue()

        // The file was readable when it was queued, but that was potentially
        // many minutes and several titles ago. Failing here with a clear
        // message beats failing inside the MTP layer with a generic I/O error.
        guard FileManager.default.isReadableFile(atPath: item.url.path) else {
            installQueue[index].state = .failed(String(localized: "\(item.name) is no longer readable. It may have been moved, renamed or ejected."))
            activeInstallItemID = nil
            persistInstallQueue()
            scheduleInstallQueueDrain()
            return false
        }

        DebugLog.write("install queue -> start \(item.name) on \(storage.name) (attempt \(installQueue[index].attempts)/\(Self.maxInstallAttempts))")
        upload(sourceURLs: [item.url], to: storage, destination: "/")
        return true
    }

    /// Records the outcome of the active queue item and advances the queue.
    ///
    /// Called from the upload done callback for every upload; a no-op when the
    /// finished transfer was not a queued install.
    ///
    /// A failed upload is put back at the head of the queue rather than written
    /// off immediately: the console is usually fine, the *session* is not, and
    /// the caller resets it. Only after `maxInstallAttempts` does the item stay
    /// failed and the batch move on.
    func finishActiveInstall(errorString: String?, hint: String? = nil) {
        defer {
            // Always try to advance: a failed title should not strand the rest
            // of the queue, and the user explicitly asked for unattended
            // sequential installs.
            persistInstallQueue()
            scheduleInstallQueueDrain()
        }

        guard let id = activeInstallItemID else { return }
        activeInstallItemID = nil
        guard let index = installQueue.firstIndex(where: { $0.id == id }) else { return }

        if let errorString {
            DebugLog.write("install queue <- \(installQueue[index].name) FAILED: \(errorString)")
            installQueue[index].hint = hint?.isEmpty == false ? hint : nil
            switch InstallRetryPolicy.decision(attempts: installQueue[index].attempts,
                                               isCancelled: ErrorStringLocalizer.isTransferCancelledError(errorString),
                                               maxAttempts: Self.maxInstallAttempts) {
            case .cancelled:
                installQueue[index].state = .cancelled
                installQueue[index].progress = 0
                // A cancel is a deliberate stop. Draining the rest immediately
                // would fight the user, and the session is being reconnected
                // anyway, so park the remainder.
                for i in installQueue.indices where installQueue[i].state == .waiting {
                    installQueue[i].state = .cancelled
                }
            case .retry:
                let localized = ErrorStringLocalizer.localize(errorString)
                installQueue[index].lastError = localized
                installQueue[index].state = .waiting
                installQueue[index].progress = 0
                DebugLog.write("install queue <- \(installQueue[index].name) will retry "
                               + "(\(installQueue[index].attempts)/\(Self.maxInstallAttempts))")
            case .fail:
                installQueue[index].lastError = ErrorStringLocalizer.localize(errorString)
                installQueue[index].state = .failed(ErrorStringLocalizer.localize(errorString))
            }
        } else {
            DebugLog.write("install queue <- \(installQueue[index].name) sent OK")
            installQueue[index].state = .sent
            installQueue[index].progress = 1
            installQueue[index].hint = nil
        }
    }
}
