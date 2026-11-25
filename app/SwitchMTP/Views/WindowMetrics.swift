// SwitchMTP Batch — a macOS MTP client for Nintendo Switch running DBI.
// Copyright (C) 2025 fratei
//
// This program is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License version 2 as published by
// the Free Software Foundation.

// Single source of truth for window sizes.
//
// These numbers used to live in three files (InitialWindowSize,
// BatchWorkspaceWindow and BatchInstallView) and drifted apart: the main
// window silently went back to upstream's 900 x 450 while the workspace kept
// asking for 880 x 520, so the "popup" covered the whole window.
//
// Everything here is expressed in *window frames* — what CGWindowList and the
// Accessibility API report, and what the user perceives as window size. A
// SwiftUI window is `fullSizeContentView`, so its content view runs under the
// title bar; the layout content area is shorter than the frame by the
// title/toolbar strip. Enforcing frames avoids mixing the two coordinate
// spaces, which is what previously made a "1000 x 620 content" window come
// out at 1000 x 672 and kept the floor from being obvious.
//
// Invariant:
//
//   main frame >= 1000 x 620
//   workspace frame <= main frame - (120 x 100)
//
// On the default sizes the workspace is 880 x 520 inside a 1000 x 620 parent:
// 60pt visible left/right and 24pt above/below inside the 1000 x 568 content
// area. See AGENTS.md §5 before changing anything here.

import AppKit

enum WindowMetrics {
    /// The main window's minimum window frame, enforced on every launch and
    /// again whenever the workspace is opened.
    static let mainMinFrame = NSSize(width: 1000, height: 620)

    /// Upstream's untouched window frame (title bar included). Used only to
    /// recognise a fresh install that has never been sized.
    static let upstreamFrame = NSSize(width: 900, height: 450)

    /// Default workspace window frame. Deliberately 880 x 520 against the
    /// 1000 x 620 parent.
    static let workspaceFrame = NSSize(width: 880, height: 520)

    /// The workspace must stay readable, so it may shrink only this far when
    /// the parent itself is smaller than expected (small screens).
    static let workspaceMinFrame = NSSize(width: 860, height: 470)

    /// Space that must stay visible around the workspace.
    static let workspaceInset = NSSize(width: 120, height: 100)

    /// Clamp the workspace to the parent's frame so it can never cover the
    /// parent, while respecting its own readability floor.
    static func workspaceFrameSize(forParentFrame parent: NSSize) -> NSSize {
        let width = max(workspaceMinFrame.width,
                        min(workspaceFrame.width, parent.width - workspaceInset.width))
        let height = max(workspaceMinFrame.height,
                         min(workspaceFrame.height, parent.height - workspaceInset.height))
        return NSSize(width: width, height: height)
    }

    /// Make sure the main window's frame is at least `mainMinFrame`, growing it
    /// back if it was restored (or resized) smaller. Keeps the top-left corner
    /// and keeps the window on screen. Safe to call repeatedly.
    static func enforceMainFloor(on window: NSWindow) {
        // The drag limit has to be expressed in layout content coordinates,
        // not frame coordinates: the window's title/toolbar strip is not
        // resizable, so subtract it once.
        let chromeHeight = max(0, window.frame.height - window.contentLayoutRect.height)
        window.contentMinSize = NSSize(width: mainMinFrame.width,
                                       height: max(1, mainMinFrame.height - chromeHeight))

        var frame = window.frame
        guard frame.width < mainMinFrame.width || frame.height < mainMinFrame.height else {
            return
        }

        let height = max(frame.height, mainMinFrame.height)
        frame.origin.y += frame.height - height
        frame.size = NSSize(width: max(frame.width, mainMinFrame.width), height: height)

        if let visible = window.screen?.visibleFrame {
            if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
            if frame.minY < visible.minY { frame.origin.y = visible.minY }
            if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
            if frame.minX < visible.minX { frame.origin.x = visible.minX }
        }
        window.setFrame(frame, display: true)
    }
}
