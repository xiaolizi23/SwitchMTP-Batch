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

/// Groups scanned packages into title clusters: one base game plus its patch
/// and DLC. Shared by the GUI workspace and the CLI; no catalogue, icons or
/// UI state here.
enum BatchGrouper {

    /// - Parameters:
    ///   - packages: Packages to group, typically the output of `BatchScanner`.
    ///   - officialNames: `baseTitleID` -> official title name. Optional; when
    ///     absent a group falls back to its first file's display name.
    static func group(_ packages: [InstallPackage],
                      officialNames: [String: String] = [:]) -> [InstallPackageGroup] {
        var byKey: [String: [InstallPackage]] = [:]
        for package in packages { byKey[package.groupKey, default: []].append(package) }

        return byKey.map { key, members in
            let sorted = members.sorted { lhs, rhs in
                if lhs.contentType.sortRank != rhs.contentType.sortRank {
                    return lhs.contentType.sortRank < rhs.contentType.sortRank
                }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
            let base = sorted.first { $0.contentType == .base } ?? sorted.first!
            let official = base.baseTitleID.flatMap { officialNames[$0] }
            return InstallPackageGroup(
                id: key,
                name: official ?? base.displayName,
                baseTitleID: base.baseTitleID,
                packages: sorted)
        }
    }
}
