// SwitchMTP Batch — a macOS MTP client for Nintendo Switch running DBI.
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

/// Headless, UI-free batch scanning.
///
/// The GUI workspace and the command line share this logic: walk the given
/// roots, keep the installable containers, run the structural inspector on
/// each, and produce the package list the plan is built from. No AppKit, no
/// published state, no network catalogue here — display names fall back to
/// the file/folder name, exactly like the GUI before its title tables load.
enum BatchScanner {

    /// Directory names that can never hold installable packages but can hold
    /// tens of thousands of files, so descending into them is never worth it.
    private static let skippedDirectoryNames: Set<String> = [
        ".git", "node_modules", "$recycle.bin", "system volume information"
    ]

    /// Recursively collects installable files under `urls` and runs the
    /// structural inspector on each.
    ///
    /// - Parameters:
    ///   - urls: Files and/or folders to scan.
    ///   - existingPaths: Standardized paths from a prior scan; matching files
    ///     are skipped so a merge does not re-inspect unchanged packages.
    ///   - excludedPaths: Standardized paths the user removed from the plan by
    ///     hand. They are skipped exactly like `existingPaths`, so re-scanning
    ///     the same folder cannot resurrect a row that was deleted on purpose.
    ///   - progress: Called with the running package count and the folder being
    ///     walked. Optional; the GUI uses it for its scanning headline.
    /// - Returns: Packages in walk order, not grouped or sorted.
    static func scan(urls: [URL],
                     existingPaths: Set<String> = [],
                     excludedPaths: Set<String> = [],
                     shouldCancel: () -> Bool = { false },
                     progress: ((_ found: Int, _ folder: String) -> Void)? = nil) -> [InstallPackage] {
        var found: [(URL, PackageFormat, Int64)] = []
        var seen = existingPaths.union(excludedPaths)
        var scannedDirs = 0

        func walk(_ url: URL) {
            if shouldCancel() { return }
            let values = try? url.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
            ])
            if values?.isSymbolicLink == true { return }

            if values?.isDirectory == true {
                scannedDirs += 1
                let name = url.lastPathComponent.lowercased()
                if skippedDirectoryNames.contains(name) || name.hasSuffix(".app") { return }
                if scannedDirs % 40 == 0 {
                    progress?(found.count, url.lastPathComponent)
                }
                guard let contents = try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
                for child in contents {
                    if shouldCancel() { return }
                    walk(child)
                }
                return
            }

            guard values?.isRegularFile == true else { return }
            let name = url.lastPathComponent
            if name.hasPrefix(".") { return }
            guard let format = PackageFormat.from(url: url),
                  let size = values?.fileSize, size > 64 else { return }
            let key = url.standardizedFileURL.path
            guard !seen.contains(key) else { return }
            seen.insert(key)
            found.append((url, format, Int64(size)))
        }

        for root in urls { walk(root) }

        return found.map { item in
            var package = InstallPackage(
                url: item.0,
                format: item.1,
                fileSize: item.2,
                displayName: PackageInspector.displayName(for: item.0))
            let report = PackageInspector.inspect(url: item.0, format: item.1)
            package.report = report
            package.notes = report.issues
            package.quickVerdict = report.verdict
            package.titleID = report.titleID
            package.contentType = report.contentType
            package.version = report.version
            if let id = report.titleID, let value = UInt64(id, radix: 16) {
                // Normalise to the application title ID: clear the patch bit and
                // the add-on bit (bits 0-12). Clearing 16 bits would also erase
                // part of the game identifier.
                package.baseTitleID = String(format: "%016llX", value & ~0x1FFF)
            }
            package.isSelected = report.verdict != .blocked
            return package
        }
    }
}
