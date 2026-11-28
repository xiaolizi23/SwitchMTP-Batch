// SwitchMTP Batch — a macOS MTP client for Nintendo Switch running DBI.
// Copyright (C) 2025 fratei
//
// This program is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License version 2 as published by
// the Free Software Foundation.

// Presents the batch workspace as its own window.
//
// It used to be a `.sheet`. A sheet on macOS is attached under the title bar,
// cannot be dragged, and — because its content asks for 890 x 520 — it came
// out larger than the 900 x 450 main window it hung from, so it spilled past
// the bottom edge and read as a panel that had slid off. A workspace this big
// is also what Apple's own guidance calls a window rather than a sheet, so it
// is one now: centred over the main window, movable, resizable.
//
// Size comes from WindowMetrics and is clamped against the parent's frame, so
// it always reads as a panel layered on a window rather than a replacement of
// it: 890 x 520 inside a 1010 x 620 window (60pt left/right, 24pt above and
// below the content area). Do not hard-code a size here: the last regression
// came from exactly that (890 x 520 hard-coded against a parent that had
// silently shrunk to 900 x 450).

import SwiftUI
import AppKit

final class BatchWorkspaceController: NSObject, NSWindowDelegate {
    /// Shared so the Switch menu and the sidebar drop zones can hand files to
    /// the same workspace the toolbar button opens.
    static let shared = BatchWorkspaceController()

    private var windowController: NSWindowController?
    /// Rebuilt every time the workspace opens: closing the window drops the
    /// prepared list, so a later drop starts a fresh batch instead of resuming
    /// an old one. While the window stays open, further drops append to it.
    private var model: BatchInstallModel?

    /// Bring an already-open workspace forward instead of opening a second one.
    func show(manager: MTPManager) {
        if let window = windowController?.window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let model = ensureModel(manager: manager)
        let host = hostWindow()
        // The parent frame only matters for the first open: it decides the
        // starting size and position so the window visibly belongs to the
        // main window. Once open it is a normal, freely resizable window.
        // The workspace must never open over a parent that has slipped below
        // the floor (restored frame, accessibility resize). Grow the parent
        // first, then size against its real content area.
        if let host {
            WindowMetrics.enforceMainFloor(on: host)
        }
        let hostContent = host?.frame.size ?? WindowMetrics.mainMinFrame
        let size = WindowMetrics.workspaceFrameSize(forParentFrame: hostContent)

        let root = BatchInstallSheet(manager: manager, model: model) { [weak self] in
            self?.close()
        }
        let hosting = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: hosting)
        window.title = String(localized: "批量安装")
        // The window draws no title of its own: the workspace header inside
        // says "批量安装" already, and having it twice 40pt apart read as a
        // mistake. Content runs up under the title bar so the header row acts
        // as the title (the traffic lights keep their own strip).
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        // It is opened on demand from the toolbar; it must not come back on
        // the next launch as a second restored window.
        window.isRestorable = false
        // Size in frame coordinates, exactly — the workspace is a plain
        // titled window with the title bar drawn transparent, so this is the
        // size the user sees. contentMinSize is derived by subtracting the
        // non-resizable title strip once.
        let chromeHeight = max(0, window.frame.height - window.contentLayoutRect.height)
        window.contentMinSize = NSSize(width: WindowMetrics.workspaceMinFrame.width,
                                       height: max(1, WindowMetrics.workspaceMinFrame.height - chromeHeight))
        // No cap: the workspace stops being tied to the parent once it is on
        // screen, so the user can grow it past the main window if they want.
        window.maxSize = NSSize(width: 10000, height: 10000)
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
        window.delegate = self

        let windowController = NSWindowController(window: window)
        self.windowController = windowController
        position(window, over: host)
        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    /// Import files or folders into the batch list, opening the workspace
    /// first if it is not on screen. `target` pre-selects the install storage;
    /// it is ignored when that target is not present on the connected console.
    func enqueue(manager: MTPManager, urls: [URL], target: StorageKind?) {
        guard !urls.isEmpty else { return }
        show(manager: manager)
        guard let model else { return }
        if let target, manager.installTargets.contains(where: { $0.kind == target }) {
            model.targetKind = target
        }
        model.importURLs(urls)
    }

    /// Opens the workspace for a queue restored at launch — either a crash
    /// resume or a parked soft-pause — and imports the folders the queued
    /// files live in, so the whole group shows up with live progress instead
    /// of an empty list the user has to re-import by hand. No-op when nothing
    /// is queued, so a normal cold start is not disturbed.
    func showRestoredQueue(manager: MTPManager) {
        guard manager.hasQueuedInstalls else { return }
        show(manager: manager)
        guard let model else { return }
        let parents = Set(manager.installQueue.map {
            $0.url.deletingLastPathComponent().standardizedFileURL
        }).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !parents.isEmpty else { return }
        model.importURLs(Array(parents))
    }

    private func ensureModel(manager: MTPManager) -> BatchInstallModel {
        if let model { return model }
        let model = BatchInstallModel(manager: manager)
        self.model = model
        return model
    }

    func close() {
        model?.cancelDeepCheck()
        windowController?.window?.close()
        windowController = nil
        model = nil
    }

    func windowWillClose(_ notification: Notification) {
        model?.cancelDeepCheck()
        windowController = nil
        model = nil
    }

    /// The app's main window, never the workspace itself.
    private func hostWindow() -> NSWindow? {
        if let main = NSApp.mainWindow, main !== windowController?.window {
            return main
        }
        if let key = NSApp.keyWindow, key !== windowController?.window {
            return key
        }
        return NSApp.windows.first {
            $0.isVisible && $0 !== windowController?.window && $0.styleMask.contains(.titled)
        }
    }

    /// Centre on the main window's content area — not on its whole frame, or
    /// the workspace ends up flush under the parent's toolbar with all the
    /// spare space at the bottom. The window is sized in frame coordinates
    /// (890 x 520) and then centred in a 1010 x 568 content area, which leaves
    /// 60pt left/right and 24pt top/bottom.
    private func position(_ window: NSWindow, over parent: NSWindow?) {
        guard let parent else {
            window.center()
            return
        }
        let frameSize = window.frame.size
        let host = parent.frame
        // `contentRect(forFrameRect:)` equals the frame for SwiftUI
        // full-size-content windows, so derive the usable area from
        // contentLayoutRect instead: title/toolbar strip at the top, content
        // below it.
        let chromeHeight = max(0, parent.frame.height - parent.contentLayoutRect.height)
        let contentHeight = max(0, host.height - chromeHeight)
        let screenFrame = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        var origin = NSPoint(x: host.midX - frameSize.width / 2,
                             y: host.minY + (contentHeight - frameSize.height) / 2)
        if let frame = screenFrame {
            origin.x = min(max(origin.x, frame.minX), frame.maxX - frameSize.width)
            origin.y = min(max(origin.y, frame.minY), frame.maxY - frameSize.height)
        }
        window.setFrameOrigin(origin)
    }
}
