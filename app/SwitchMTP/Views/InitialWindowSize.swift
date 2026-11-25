// SwitchMTP Batch — a macOS MTP client for Nintendo Switch running DBI.
// Copyright (C) 2025 fratei
//
// This program is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License version 2 as published by
// the Free Software Foundation.

// Seeds the very first window at a slightly roomier size than upstream's
// 900 x 450.
//
// The batch workspace is 880 x 540 and is meant to read as a panel layered on
// the main window rather than a replacement of it, so the parent has to be
// bigger than the child with its edges visible. `Scene.defaultSize` would say
// this in one line, but it is macOS 13 and this app still deploys to 12, and
// SceneBuilder rejects an `if #available` branch. Setting the frame from
// AppKit keeps one code path for every supported version.
//
// Deliberately conservative: it runs exactly once per installation, and only
// when the window still has upstream's untouched 900 x 450 size. A window the
// user has resized is left alone and simply marks the one-time seed as done.

import SwiftUI
import AppKit

struct InitialWindowSize: NSViewRepresentable {
    let size: NSSize

    private static let seedKey = "batch.windowSeedApplied"
    private static let upstreamSize = NSSize(width: 900, height: 450)

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The window is not attached yet while makeNSView runs.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            Self.apply(to: window, size: size)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private static func apply(to window: NSWindow, size: NSSize) {
        let defaults = UserDefaults.standard
        // One-time: after this the window frame is whatever the user left it as.
        guard !defaults.bool(forKey: seedKey) else { return }

        defer { defaults.set(true, forKey: seedKey) }
        // Never touch a window the user has already sized themselves; 900 x 450
        // is upstream's untouched default and the only case worth seeding.
        // Compared as frames: the title bar is part of the 450.
        guard window.frame.size == upstreamSize else { return }

        window.setContentSize(size)
        window.center()
    }
}
