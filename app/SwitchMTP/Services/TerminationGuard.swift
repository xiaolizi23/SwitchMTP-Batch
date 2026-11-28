// SwitchMTP Batch — a macOS MTP client for Nintendo Switch running DBI.
// Copyright (C) 2025 fratei
//
// This program is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License version 2 as published by
// the Free Software Foundation.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
// Public License for more details.

import AppKit

/// Confirms a normal quit while installs are still in flight.
///
/// This only guards the graceful quit path: ⌘Q, the app menu's "Quit", and any
/// other route that lets `applicationShouldTerminate` run. It cannot — and is
/// not expected to — catch a force-quit, a power loss, a hang-and-kill, or a
/// cable pull; those terminate the process before any alert can be shown, and
/// the console rolls the half-written package back on its own side.
final class TerminationGuard: NSObject, NSApplicationDelegate {

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let manager = MTPManager.shared, manager.pendingInstallCount > 0 else {
            return .terminateNow
        }

        var lines: [String] = []
        if let active = manager.activeInstallTitle {
            lines.append("正在传输：\(active)")
        }
        if manager.queuedInstallCount > 0 {
            lines.append("排队中：\(manager.queuedInstallCount) 项")
        }
        let summary = lines.joined(separator: "\n")

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "当前还有安装任务在进行，确定要退出吗？"
        alert.informativeText = summary + "\n退出会中断当前传输；未完成的项下次打开会重新排队。"
        alert.addButton(withTitle: "继续退出")
        alert.addButton(withTitle: "取消")

        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}
