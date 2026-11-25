// SwitchMTP Batch — a macOS MTP client for Nintendo Switch running DBI.
// Copyright (C) 2025 fratei
//
// This program is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License version 2 as published by
// the Free Software Foundation.

// Enforces the main window's minimum size on every launch.
//
// `Scene.defaultSize` would state the preferred size in one line, but it is
// macOS 13 and this app still deploys to 12, and SceneBuilder rejects an
// `if #available` branch. Setting the frame from AppKit keeps one code path
// for every supported version.
//
// This used to be a one-time seed guarded by `batch.windowSeedApplied`. That
// flag survives reinstalls while the window frame is autosaved and restored
// separately, so once the flag was set the app could come back at upstream's
// 900 x 450 forever — the workspace (880 x 520) then covered the whole window.
// The floor is now unconditional:
//
//   - contentMinSize is always 1000 x 620;
//   - a restored frame smaller than that is grown back, top edge anchored;
//   - the preferred 1000 x 620 is applied (and centred) only on a virgin
//     install, so a user's own larger window is never touched.
//
// See WindowMetrics and AGENTS.md §5.

import SwiftUI
import AppKit

struct InitialWindowSize: NSViewRepresentable {
    let size: NSSize

    private static let seedKey = "batch.windowSeedApplied"

    final class Coordinator {
        fileprivate var resizeObserver: NSObjectProtocol?
        fileprivate var isEnforcing = false

        deinit {
            if let resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The window is not attached yet while makeNSView runs.
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            Self.apply(to: window, minimum: size)
            Self.observeResizes(of: window, minimum: size, coordinator: context.coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let observer = coordinator.resizeObserver {
            NotificationCenter.default.removeObserver(observer)
            coordinator.resizeObserver = nil
        }
    }

    /// `contentMinSize` is not reliably enforced for SwiftUI windows (frame
    /// restoration and Accessibility resizing can both slip under it), so the
    /// floor is also re-applied whenever the window resizes below it. The
    /// reentrancy flag stops our own setFrame from feeding back.
    private static func observeResizes(of window: NSWindow,
                                       minimum: NSSize,
                                       coordinator: Coordinator) {
        guard coordinator.resizeObserver == nil else { return }
        coordinator.resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak window, weak coordinator] _ in
            guard let window, let coordinator, !coordinator.isEnforcing else { return }
            guard window.frame.width < minimum.width || window.frame.height < minimum.height else {
                return
            }
            coordinator.isEnforcing = true
            WindowMetrics.enforceMainFloor(on: window)
            coordinator.isEnforcing = false
        }
    }

    private static func apply(to window: NSWindow, minimum: NSSize) {
        let defaults = UserDefaults.standard

        // A fresh install still at upstream's untouched frame gets the
        // preferred size and is centred. This is the only time we move a
        // window the user has not touched.
        if !defaults.bool(forKey: seedKey),
           window.frame.size == WindowMetrics.upstreamFrame {
            defaults.set(true, forKey: seedKey)
            window.setFrame(NSRect(origin: window.frame.origin, size: minimum), display: false)
            window.center()
            return
        }
        defaults.set(true, forKey: seedKey)

        // The floor applies no matter what state the window was restored in.
        WindowMetrics.enforceMainFloor(on: window)
    }
}
