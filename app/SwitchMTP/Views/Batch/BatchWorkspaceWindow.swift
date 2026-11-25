// SwitchMTP Batch — a macOS MTP client for Nintendo Switch running DBI.
// Copyright (C) 2025 fratei
//
// This program is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License version 2 as published by
// the Free Software Foundation.

// Presents the batch workspace as its own window.
//
// It used to be a `.sheet`. A sheet on macOS is attached under the title bar,
// cannot be dragged, and — because its content asks for 880 x 540 — it came
// out larger than the 900 x 450 main window it hung from, so it spilled past
// the bottom edge and read as a panel that had slid off. A workspace this big
// is also what Apple's own guidance calls a window rather than a sheet, so it
// is one now: centred over the main window, movable, resizable.
//
// Size is deliberate: 880 x 520 against a 1000 x 620 main window leaves 60pt
// of the parent visible on each side and 22pt above and below, which is what
// makes it read as a panel layered on a window rather than a replacement.

import SwiftUI
import AppKit

final class BatchWorkspaceController: NSObject, NSWindowDelegate {
    private var windowController: NSWindowController?

    /// Bring an already-open workspace forward instead of opening a second one.
    func show(manager: MTPManager) {
        if let window = windowController?.window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let size = NSSize(width: 880, height: 520)
        let root = BatchInstallSheet(manager: manager) { [weak self] in
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
        window.contentMinSize = NSSize(width: 880, height: 520)
        window.setContentSize(size)
        window.delegate = self

        let windowController = NSWindowController(window: window)
        self.windowController = windowController
        position(window)
        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        windowController?.window?.close()
        windowController = nil
    }

    func windowWillClose(_ notification: Notification) {
        windowController = nil
    }

    /// Centre on the main window's content area — not on its whole frame, or
    /// the workspace clips the parent's title bar and the parent stops looking
    /// like the window it belongs to.
    private func position(_ window: NSWindow) {
        guard let parent = NSApp.keyWindow ?? NSApp.mainWindow else {
            window.center()
            return
        }
        // Window frames, not content sizes: the title bar is part of the
        // window being centred and ignoring it shifts the result up by half
        // its height.
        let frameSize = window.frame.size
        let host = parent.contentRect(forFrameRect: parent.frame)
        let screenFrame = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        var origin = NSPoint(x: host.midX - frameSize.width / 2,
                             y: host.midY - frameSize.height / 2)
        if let frame = screenFrame {
            origin.x = min(max(origin.x, frame.minX), frame.maxX - frameSize.width)
            origin.y = min(max(origin.y, frame.minY), frame.maxY - frameSize.height)
        }
        window.setFrameOrigin(origin)
    }
}
