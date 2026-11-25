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

// The batch-install workspace: "collect first, review second, install last".
//
// SwitchMTP's original install flow starts an upload the instant a file is
// dropped. That is fine for one title and useless for twenty, and it cannot
// answer the question the user actually has before a two-hour install run:
// "what is in this folder, and will DBI reject any of it?"

import Foundation

/// Container format, taken from the extension. NSZ/XCZ are NSP/XCI whose
/// NCAs are individually zstd-compressed; the outer container is unchanged.
enum PackageFormat: String, CaseIterable, Sendable {
    case nsp, nsz, xci, xcz

    var isCompressed: Bool { self == .nsz || self == .xcz }
    var isCartridgeImage: Bool { self == .xci || self == .xcz }

    var displayName: String { rawValue.uppercased() }

    static func from(url: URL) -> PackageFormat? {
        PackageFormat(rawValue: url.pathExtension.lowercased())
    }
}

/// What a package is, relative to the base game it belongs to.
///
/// Retail title IDs encode this in the low 16 bits: `…0000` is the application,
/// `…0800` is its patch (update), and every other value is add-on content that
/// sits at a `0x1000` step above the application. When the container exposes
/// nothing better, the folder and file name decide, and the UI says so.
enum PackageContentType: String, Sendable {
    case base
    case update
    case dlc
    case unknown

    var displayName: String {
        switch self {
        case .base: return "本体"
        case .update: return "更新"
        case .dlc: return "DLC"
        case .unknown: return "未识别"
        }
    }

    var englishName: String {
        switch self {
        case .base: return "Base game"
        case .update: return "Update"
        case .dlc: return "Add-on"
        case .unknown: return "Unknown"
        }
    }

    /// Rank used to keep a title group in install order: base, then update,
    /// then add-ons. DBI installs fine in any order, but a base followed by
    /// its patch is what people expect to see.
    var sortRank: Int {
        switch self {
        case .base: return 0
        case .update: return 1
        case .dlc: return 2
        case .unknown: return 3
        }
    }
}

/// The three-state result the workspace promises, plus "not looked at yet".
///
/// This is *our own* local verdict. DBI still decides what happens on the
/// console and shows its own progress screen; the app never claims to have
/// installed anything, only that the bytes were delivered.
enum PackageVerdict: String, Sendable {
    /// Structure is sound *and* every NCA carried a retail signature.
    /// This is the only state that really equals DBI's green.
    case passed
    /// Structure is sound, but signatures were never checked (no keyset, or a
    /// compressed package). Honest label: "installable, not proven retail".
    /// Must never be shown as the same colour as `passed`.
    case unverified
    /// Installable, but known not to be retail-signed (bad signature, no
    /// ticket). This is the state that matches DBI's yellow after install.
    case caution
    /// Broken, truncated or self-contradictory. Default-excluded from the plan.
    case blocked
    /// Quick check has not finished yet.
    case pending

    var displayName: String {
        switch self {
        case .passed: return "已验证原版"
        case .unverified: return "未验签"
        case .caution: return "注意"
        case .blocked: return "阻止"
        case .pending: return "待检查"
        }
    }

    var shortSymbol: String {
        switch self {
        case .passed: return "checkmark.seal.fill"
        case .unverified: return "checkmark.circle"
        case .caution: return "exclamationmark.triangle.fill"
        case .blocked: return "xmark.octagon.fill"
        case .pending: return "circle.dotted"
        }
    }

    var rank: Int {
        switch self {
        case .blocked: return 0
        case .caution: return 1
        case .unverified: return 2
        case .pending: return 3
        case .passed: return 4
        }
    }
}

enum CheckSeverity: String, Sendable {
    case note
    case warning
    case blocking
}

/// One observation produced by the inspector. Kept as data rather than a
/// formatted string so the detail pane can group them and the confirm sheet
/// can count them.
struct CheckNote: Identifiable, Hashable, Sendable {
    let id = UUID()
    let severity: CheckSeverity
    let title: String
    let detail: String

    init(severity: CheckSeverity, title: String, detail: String = "") {
        self.severity = severity
        self.title = title
        self.detail = detail
    }
}

/// Deep-verification state, deliberately separate from the quick verdict.
///
/// A quick structural pass is free and fast; decrypting NCAs and verifying
/// RSA signatures is neither, and needs `prod.keys`. Keeping the two apart
/// stops a green structural result from being mistaken for "signature checked".
enum DeepCheckState: String, Sendable {
    case notRun
    case running
    case verified          // retail signature and content hash both verified
    case signatureOnly     // retail signature verified, content hashes unavailable
    case signatureInvalid  // readable, but signed by something other than retail
    case failed            // hash/content mismatch or unreadable
    case unavailable       // no keys, or a compressed package needing unpacking

    var displayName: String {
        switch self {
        case .notRun: return "未深度检查"
        case .running: return "正在深度检查"
        case .verified: return "签名与哈希通过"
        case .signatureOnly: return "签名通过 · 哈希未验"
        case .signatureInvalid: return "签名非官方"
        case .failed: return "哈希或内容不符"
        case .unavailable: return "无法深度验证"
        }
    }
}

/// A parsed entry inside a container, kept only as far as it is useful for
/// naming and metadata. `absoluteOffset` lets a later deep pass seek straight
/// to an NCA without re-walking the table.
struct ContainerEntry: Hashable, Sendable {
    let name: String
    let offset: Int64
    let size: Int64
    let absoluteOffset: Int64
}

/// Everything the structural pass learned about one file.
struct ContainerReport: Sendable {
    var format: PackageFormat
    var entries: [ContainerEntry] = []
    var issues: [CheckNote] = []
    var titleID: String?
    var contentType: PackageContentType = .unknown
    var version: Int?
    var hasTicket = false
    var hasCertificate = false
    var hasCnmt = false
    var ncaCount = 0
    /// True when NCA payloads were found to be NCZ/zstd streams, which only a
    /// decompressing checker can look inside.
    var compressedContent = false
    /// Container-level verdict before any key is involved.
    var verdict: PackageVerdict = .pending

    var titleIDDisplay: String { titleID ?? "—" }

    var isStructurallySound: Bool { verdict == .passed || verdict == .unverified || verdict == .caution }
}

/// One file the user may choose to send.
struct InstallPackage: Identifiable, Sendable {
    let id: UUID
    let url: URL
    let format: PackageFormat
    let fileSize: Int64
    let displayName: String
    var titleID: String?
    var baseTitleID: String?
    var contentType: PackageContentType = .unknown
    var version: Int?
    var report: ContainerReport?
    var quickVerdict: PackageVerdict = .pending
    var deepState: DeepCheckState = .notRun
    /// Per-NCA outcome of the last deep pass, kept for the detail pane.
    var deepNCAs: [DeepVerifier.NCACheck] = []
    var notes: [CheckNote] = []
    var isSelected = false
    /// Handed to DBI by this run. Kept in the workspace so the user can still
    /// see what the batch contained and what is left, rather than watching the
    /// list empty itself the moment Send is pressed.
    var isSubmitted = false

    init(url: URL, format: PackageFormat, fileSize: Int64, displayName: String) {
        self.id = UUID()
        self.url = url
        self.format = format
        self.fileSize = fileSize
        self.displayName = displayName
    }

    /// The group this file belongs to: one base title plus its patch and DLC.
    var groupKey: String {
        if let baseTitleID { return "title:" + baseTitleID.lowercased() }
        // Without a title ID there is no honest way to merge files, so the
        // containing folder becomes the unit. Files dropped from one game folder
        // therefore still stay together.
        return "folder:" + url.deletingLastPathComponent().path
    }

    var sizeText: String { ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file) }

    /// The colour the row should use, after merging the two independent axes:
    /// installability (structure + hash failure) and authenticity (signature).
    ///
    /// Quick check can only answer the first axis. Deep check answers the
    /// second. A structurally clean file that was never deep-checked is
    /// `.unverified`, never `.passed` — that is the whole point of splitting
    /// the axes, and the reason a "green" file can still turn out yellow on
    /// the console.
    var resolvedVerdict: PackageVerdict {
        if quickVerdict == .blocked || deepState == .failed { return .blocked }
        if quickVerdict == .pending || deepState == .running { return .pending }
        if deepState == .signatureInvalid { return .caution }
        if quickVerdict == .caution { return .caution }
        if deepState == .verified { return .passed }
        return .unverified
    }

    var deepStateAllowsInstall: Bool {
        switch deepState {
        case .failed: return false
        default: return true
        }
    }
}

/// A title group shown as one expandable row in the plan.
struct InstallPackageGroup: Identifiable, Sendable {
    let id: String
    var name: String
    var baseTitleID: String?
    var packages: [InstallPackage]

    var totalSize: Int64 { packages.reduce(0) { $0 + $1.fileSize } }
    var selectedCount: Int { packages.filter(\.isSelected).count }
    var submittedCount: Int { packages.filter(\.isSubmitted).count }
    var hasBlocked: Bool { packages.contains { $0.resolvedVerdict == .blocked } }
    var hasCaution: Bool { packages.contains { $0.resolvedVerdict == .caution } }
    var hasUnverified: Bool { packages.contains { $0.resolvedVerdict == .unverified } }

    /// Aggregate glyph for the collapsed row: the worst member wins.
    var verdict: PackageVerdict {
        if packages.contains(where: { $0.resolvedVerdict == .blocked }) { return .blocked }
        if packages.contains(where: { $0.resolvedVerdict == .caution }) { return .caution }
        if packages.contains(where: { $0.resolvedVerdict == .pending }) { return .pending }
        if packages.contains(where: { $0.resolvedVerdict == .unverified }) { return .unverified }
        return .passed
    }

    var sizeText: String { ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file) }
}

/// The review surface's filter, mirroring SwitchDownloader's scan-page pills
/// without copying its code or layout.
enum PlanFilter: String, CaseIterable, Sendable {
    case all
    case needsAttention
    case onlyUpdatesAndDLC
    case onlyBase

    var displayName: String {
        switch self {
        case .all: return "全部"
        case .needsAttention: return "有问题"
        case .onlyUpdatesAndDLC: return "仅更新/DLC"
        case .onlyBase: return "仅本体"
        }
    }
}

enum PlanSort: String, CaseIterable, Sendable {
    case title
    case size
    case status
    case path

    var displayName: String {
        switch self {
        case .title: return "名称"
        case .size: return "大小"
        case .status: return "状态"
        case .path: return "路径"
        }
    }
}

/// Turns the selected files into the order DBI receives them.
///
/// Two levels, and both matter:
///
/// 1. *Titles stay whole.* Every file of one title is emitted as a block, so a
///    title is never interrupted by another game's file. The blocks themselves
///    are ordered by the title's display name, falling back to the group key so
///    the result is deterministic.
/// 2. *Inside a block: base, then update, then add-ons.* DBI refuses an update
///    whose base is not on the console yet, so this is not cosmetic.
///
/// The previous version sorted the whole selection in one pass, comparing
/// `displayName` across groups and `sortRank` inside them. Those two rules
/// together are not a valid ordering (they can form a cycle), so `sort` was
/// free to emit anything — in the worst case an update ahead of its own base.
enum InstallPlanOrder {
    /// - Parameters:
    ///   - packages: the files the user ticked.
    ///   - groupTitles: group key -> the official title shown in the list; used
    ///     only for block ordering. Unknown keys fall back to the first file's
    ///     name, so a plan built before the name catalogues load is still
    ///     stable.
    static func ordered(_ packages: [InstallPackage],
                        groupTitles: [String: String] = [:]) -> [InstallPackage] {
        var buckets: [String: [InstallPackage]] = [:]
        for package in packages { buckets[package.groupKey, default: []].append(package) }
        guard !buckets.isEmpty else { return [] }

        // The name used to order blocks. An official title is preferred; without
        // one, the alphabetically-first file name stands in, so the same set of
        // files always produces the same plan regardless of drop order.
        var blockTitles: [String: String] = [:]
        for (key, members) in buckets {
            if let official = groupTitles[key] {
                blockTitles[key] = official
            } else {
                blockTitles[key] = members.map(\.displayName).min {
                    $0.localizedStandardCompare($1) == .orderedAscending
                } ?? key
            }
        }

        let keys = buckets.keys.sorted { lhs, rhs in
            let left = blockTitles[lhs] ?? lhs
            let right = blockTitles[rhs] ?? rhs
            switch left.localizedStandardCompare(right) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return lhs < rhs
            }
        }

        return keys.flatMap { key -> [InstallPackage] in
            let members = buckets[key] ?? []
            return members.sorted { lhs, rhs in
                if lhs.contentType.sortRank != rhs.contentType.sortRank {
                    return lhs.contentType.sortRank < rhs.contentType.sortRank
                }
                switch lhs.displayName.localizedStandardCompare(rhs.displayName) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return lhs.url.path < rhs.url.path
                }
            }
        }
    }
}

/// What the user is about to send, captured once and frozen for the confirm
/// sheet so the numbers cannot shift underneath them.
struct InstallPlan: Sendable {
    let packages: [InstallPackage]
    let targetKind: StorageKind
    let generatedAt: Date

    var totalSize: Int64 { packages.reduce(0) { $0 + $1.fileSize } }
    var totalSizeText: String { ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file) }
    var counts: (passed: Int, unverified: Int, caution: Int, blocked: Int) {
        var p = 0, u = 0, c = 0, b = 0
        for item in packages {
            switch item.resolvedVerdict {
            case .blocked: b += 1
            case .caution: c += 1
            case .unverified, .pending: u += 1
            case .passed: p += 1
            }
        }
        return (p, u, c, b)
    }
}
