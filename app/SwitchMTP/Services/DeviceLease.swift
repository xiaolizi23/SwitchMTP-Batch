// SwitchMTP Batch — a macOS MTP client for Nintendo Switch running DBI.
// Copyright (C) 2025 fratei
//
// This program is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License version 2 as published by
// the Free Software Foundation.

import Foundation

/// Cross-process lease for the console.
///
/// macOS gives one process exclusive access to the MTP device. A second copy
/// of the app that tries to connect does not just fail: `claimWithRetry` in
/// go-mtpfs calls `libusb_reset_device` to win the PTP interface back from
/// ptpcamerad, and that reset tears down the USB device under the copy that is
/// actually connected. The two copies then keep resetting each other (once
/// every ~3 s in the logs), and nxmtp panics when its device disappears
/// mid-session.
///
/// The lease keeps the fight from starting: only the holder is allowed to
/// enumerate or open the console. Everybody else stays parked, showing which
/// instance holds it, and takes over when the holder exits (flock is released
/// by the kernel, including after a crash).
final class DeviceLease {
    static let shared = DeviceLease()

    private var fd: Int32 = -1
    private let lock = NSLock()
    private(set) var ownerDescription: String?

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("DeviceLease", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mtp-session.lock")
    }

    var isHeld: Bool {
        lock.lock(); defer { lock.unlock() }
        return fd >= 0
    }

    /// Returns true when this process may talk to the console.
    func acquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 { return true }

        let url = fileURL
        let newFD = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard newFD >= 0 else {
            // Cannot create the lock file (sandbox/FS problem). Refusing to
            // connect would be worse than the rare conflict, so let it through.
            return true
        }
        if flock(newFD, LOCK_EX | LOCK_NB) == 0 {
            fd = newFD
            let owner = "pid \(ProcessInfo.processInfo.processIdentifier)"
            ftruncate(newFD, 0)
            _ = owner.data(using: .utf8)?.withUnsafeBytes { raw in
                write(newFD, raw.baseAddress, raw.count)
            }
            ownerDescription = nil
            return true
        }
        ownerDescription = Self.readOwner(fd: newFD) ?? "另一个实例"
        close(newFD)
        return false
    }

    /// True when nobody holds the lease, without keeping it afterwards.
    func isAvailable() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 { return true }
        let newFD = open(fileURL.path, O_CREAT | O_RDWR, 0o600)
        guard newFD >= 0 else { return true }
        defer { close(newFD) }
        guard flock(newFD, LOCK_EX | LOCK_NB) == 0 else { return false }
        flock(newFD, LOCK_UN)
        return true
    }

    func release() {
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
        ownerDescription = nil
    }

    private static func readOwner(fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        lseek(fd, 0, SEEK_SET)
        let count = read(fd, &buffer, buffer.count - 1)
        guard count > 0 else { return nil }
        let text = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
