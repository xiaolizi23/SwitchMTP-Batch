// SwitchMTP Batch — a macOS MTP client for Nintendo Switch running DBI.
// Copyright (C) 2025 fratei
//
// This program is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License version 2 as published by
// the Free Software Foundation.

// Presents the confirm-plan panel as its own movable window.
//
// It used to be a `.sheet` hanging off the batch workspace. A sheet on
// macOS is attached under the parent's title bar and cannot be dragged;
// with 44 titles the panel grew taller than the workspace it hung from,
// spilled past the bottom edge, and read as a panel that had slid off.
// A confirmation list this tall is a window, not a sheet: it opens centred
// over the workspace, is freely draggable and resizable, and keeps the
// frozen plan snapshot the workspace built.

import SwiftUI
import AppKit

final class BatchConfirmController: NSObject, NSWindowDelegate {
    static let shared = BatchConfirmController()

    private var windowController: NSWindowController?
    private var onFinished: (() -> Void)?

    /// Bring an already-open panel forward instead of opening a second one.
    func show(plan: InstallPlan,
              model: BatchInstallModel,
              manager: MTPManager,
              onFinished: @escaping () -> Void) {
        // Reopen from the latest snapshot: a stale panel must not keep an old
        // plan after the list changed.
        if windowController != nil { close() }

        self.onFinished = onFinished

        let root = BatchConfirmSheet(
            plan: plan,
            model: model,
            manager: manager,
            onFinished: { [weak self] in
                self?.close()
                self?.onFinished?()
            },
            onCancel: { [weak self] in
                self?.close()
            }
        )
        let hosting = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: hosting)
        window.title = String(localized: "确认安装计划")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        // Opened on demand; it must not come back as a restored window.
        window.isRestorable = false

        // 620 frame width matches the SwiftUI root frame. The list inside
        // scrolls (maxHeight 320), so the panel keeps a usable floor and can
        // grow freely above it.
        window.setContentSize(NSSize(width: 620, height: 580))
        window.contentMinSize = NSSize(width: 620, height: 440)
        window.maxSize = NSSize(width: 10000, height: 10000)
        window.delegate = self

        let controller = NSWindowController(window: window)
        self.windowController = controller
        position(window, over: hostWindow())
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        windowController?.window?.close()
        cleanup()
    }

    func windowWillClose(_ notification: Notification) {
        cleanup()
    }

    private func cleanup() {
        windowController = nil
        onFinished = nil
    }

    /// The workspace (or main) window, never this panel itself.
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

    /// Centre over the parent's content area, clamped to the visible screen.
    private func position(_ window: NSWindow, over parent: NSWindow?) {
        guard let parent else {
            window.center()
            return
        }
        let frameSize = window.frame.size
        let host = parent.frame
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
