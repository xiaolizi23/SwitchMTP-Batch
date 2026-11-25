// SwitchMTP Batch — a macOS MTP client for Nintendo Switch running DBI.
// Copyright (C) 2025 fratei
//
// This program is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License version 2 as published by
// the Free Software Foundation.

// Key-free, offline inspection of NSP/NSZ/XCI/XCZ containers.
//
// This layer answers one question honestly: "is this a complete, well-formed
// container that names a title?" It does *not* claim to verify signatures --
// NCAs are encrypted with keys this pass never touches, so a red result here
// means provably broken structure (bad magic, out-of-bounds entry, missing
// payload), never "signature invalid". That distinction is what lets the UI
// show yellow for "could not check further" without pretending it is red.
//
// Everything is read in bounded chunks: a 25 GB XCI must not be loaded to find
// its root partition.

import Foundation

enum PackageInspector {

    // MARK: - Public entry point

    /// Runs the quick structural pass for one file. Never throws: a file that
    /// cannot be read becomes a blocked report with the reason attached, which
    /// is what the review list needs to display.
    static func inspect(url: URL, format: PackageFormat) -> ContainerReport {
        var report = ContainerReport(format: format)
        do {
            let size = try fileSize(url)
            guard size >= 64 else {
                report.verdict = .blocked
                report.issues.append(.init(severity: .blocking, title: "文件过小", detail: "只有 \(size) 字节，不可能是一个完整的安装包。"))
                return report
            }
            let reader = try RandomAccessReader(url: url, size: size)
            if format.isCartridgeImage {
                try inspectCartridge(reader, report: &report)
            } else {
                try inspectPackage(reader, report: &report)
            }
            report.titleID = titleIDFrom(names: report.entries.map(\.name))
                ?? titleIDFromFileName(url.lastPathComponent)
            if let id = report.titleID {
                report.contentType = contentType(for: id, fileName: url.lastPathComponent)
            } else {
                report.contentType = contentTypeFromName(url.lastPathComponent)
                report.issues.append(.init(
                    severity: .note,
                    title: "无法确认标题归属",
                    detail: "容器里没有可读的 CNMT 文件名，只能按文件夹/文件名归类；这不代表文件损坏，安装前请自行确认这是正确的游戏。"))
            }
            report.version = versionFromName(url.lastPathComponent)
            report.verdict = verdict(for: report)
        } catch {
            report.verdict = .blocked
            report.issues.append(.init(severity: .blocking, title: "无法读取文件", detail: describe(error)))
        }
        return report
    }

    // MARK: - NSP / NSZ (PFS0)

    private static func inspectPackage(_ reader: RandomAccessReader, report: inout ContainerReport) throws {
        let header = try reader.read(at: 0, count: 16)
        guard header.count == 16, header.string(at: 0, length: 4) == "PFS0" else {
            let got = header.string(at: 0, length: 4) ?? "?"
            report.issues.append(.init(
                severity: .blocking,
                title: "不是 PFS0 容器",
                detail: "文件头是 “\(got)”，不是 NSP/NSZ 应有的 “PFS0”。扩展名可能被改过，或文件是别的东西。"))
            return
        }
        let count = Int(header.u32(at: 4))
        let stringTableSize = Int(header.u32(at: 8))
        guard count > 0, count <= 4096 else {
            report.issues.append(.init(severity: .blocking, title: "文件表数量异常", detail: "PFS0 声明了 \(count) 个条目。"))
            return
        }
        guard stringTableSize >= 0, stringTableSize <= 16 * 1024 * 1024 else {
            report.issues.append(.init(severity: .blocking, title: "字符串表异常", detail: "声明的字符串表大小为 \(stringTableSize) 字节。"))
            return
        }
        let entryTableSize = Int64(count) * 24
        let tableEnd = 16 + entryTableSize
        let dataStart = tableEnd + Int64(stringTableSize)
        guard dataStart <= reader.size else {
            report.issues.append(.init(severity: .blocking, title: "文件表越界", detail: "头表结束于 \(dataStart)，但文件只有 \(reader.size) 字节。文件被截断。"))
            return
        }
        let entriesData = try reader.read(at: 16, count: Int(entryTableSize))
        let stringTable = try reader.read(at: tableEnd, count: stringTableSize)
        try parseEntries(entriesData, stringTable: stringTable, dataStart: dataStart,
                         sizePerEntry: 24, hashedSizeOffset: nil, reader: reader, report: &report)
        evaluateCommon(report: &report, reader: reader)
    }

    // MARK: - XCI / XCZ (HEAD + HFS0)

    private static func inspectCartridge(_ reader: RandomAccessReader, report: inout ContainerReport) throws {
        let header = try reader.read(at: 0, count: 0x200)
        guard header.count == 0x200, header.string(at: 0x100, length: 4) == "HEAD" else {
            report.issues.append(.init(
                severity: .blocking,
                title: "不是 XCI 镜像",
                detail: "0x100 处没有 “HEAD” 魔数。文件可能被截断，或只是扩展名被改成了 .xci/.xcz。"))
            return
        }
        // Header layout follows hactool's `xci_header_t`: root HFS0 offset at
        // 0x130 and its size at 0x138. 0x140/0x148 are the hash digest of that
        // header, and 0x120 is the reversed IV — reading them as numbers made
        // every real retail XCI look like a corrupt, truncated image.
        let hfs0Offset = Int64(clamping: header.u64(at: 0x130))
        let hfs0HeaderSize = Int64(clamping: header.u64(at: 0x138))

        guard hfs0Offset > 0, hfs0Offset < reader.size, hfs0HeaderSize > 0, hfs0Offset + hfs0HeaderSize <= reader.size else {
            report.issues.append(.init(severity: .blocking, title: "根分区位置无效", detail: "根 HFS0 偏移 \(hfs0Offset)、大小 \(hfs0HeaderSize) 超出文件范围。"))
            return
        }

        var rootReport = ContainerReport(format: report.format)
        try parseHFS0(reader, at: hfs0Offset, label: "根分区", allowNested: true, rootReport: &rootReport, report: &report)

        // The secure partition is the one that carries game NCAs; update,
        // normal and logo are firmware/card metadata.
        guard let secure = rootReport.entries.first(where: { $0.name.lowercased() == "secure" }) else {
            report.issues.append(.init(severity: .blocking, title: "缺少 secure 分区", detail: "卡带镜像里没有 secure 分区，无法安装。"))
            return
        }
        var secureReport = ContainerReport(format: report.format)
        try parseHFS0(reader, at: secure.absoluteOffset, label: "secure 分区", allowNested: false, rootReport: &secureReport, report: &report)
        // Counts and content flags live on the partition report; the outer
        // report is what the UI reads, so carry them across explicitly.
        report.entries = secureReport.entries
        report.ncaCount = secureReport.ncaCount
        report.hasCnmt = secureReport.hasCnmt
        report.hasTicket = secureReport.hasTicket
        report.hasCertificate = secureReport.hasCertificate
        report.compressedContent = secureReport.compressedContent
        evaluateCommon(report: &report, reader: reader)
    }

    /// Parses one HFS0 directory at `offset`. When `allowNested` is set the
    /// caller is the root of an XCI, and only the partition names are kept;
    /// otherwise the NCAs inside a partition are kept as the real entries.
    private static func parseHFS0(_ reader: RandomAccessReader, at offset: Int64, label: String,
                                  allowNested: Bool, rootReport: inout ContainerReport,
                                  report: inout ContainerReport) throws {
        let header = try reader.read(at: offset, count: 16)
        guard header.count == 16, header.string(at: 0, length: 4) == "HFS0" else {
            report.issues.append(.init(
                severity: .blocking,
                title: "\(label) 不是 HFS0",
                detail: "偏移 \(offset) 处没有 HFS0 魔数。"))
            return
        }
        let count = Int(header.u32(at: 4))
        let stringTableSize = Int(header.u32(at: 8))
        guard count > 0, count <= 512 else {
            report.issues.append(.init(severity: .blocking, title: "\(label) 条目数量异常", detail: "声明了 \(count) 个条目。"))
            return
        }
        guard stringTableSize >= 0, stringTableSize <= 8 * 1024 * 1024 else {
            report.issues.append(.init(severity: .blocking, title: "\(label) 字符串表异常", detail: "声明大小 \(stringTableSize) 字节。"))
            return
        }
        let entryTableSize = Int64(count) * 64
        let tableEnd = offset + 16 + entryTableSize
        let dataStart = tableEnd + Int64(stringTableSize)
        guard dataStart <= reader.size else {
            report.issues.append(.init(severity: .blocking, title: "\(label) 越界", detail: "头表结束于 \(dataStart)，文件只有 \(reader.size) 字节。"))
            return
        }
        let entriesData = try reader.read(at: offset + 16, count: Int(entryTableSize))
        let stringTable = try reader.read(at: tableEnd, count: stringTableSize)
        try parseEntries(entriesData, stringTable: stringTable, dataStart: dataStart,
                         sizePerEntry: 64, hashedSizeOffset: nil, reader: reader, report: &rootReport)
        _ = allowNested
    }

    /// Shared entry-table walker for PFS0 (24-byte rows) and HFS0 (64-byte rows).
    private static func parseEntries(_ entriesData: Data, stringTable: Data, dataStart: Int64,
                                     sizePerEntry: Int, hashedSizeOffset: Int?,
                                     reader: RandomAccessReader, report: inout ContainerReport) throws {
        var seen = Set<String>()
        var ranges: [(Int64, Int64, String)] = []
        let entryCount = entriesData.count / sizePerEntry

        for index in 0..<entryCount {
            let row = index * sizePerEntry
            guard entriesData.count >= row + sizePerEntry else { break }
            let entryOffset = Int64(clamping: entriesData.u64(at: row))
            let size = Int64(clamping: entriesData.u64(at: row + 8))
            let nameOffset = Int(entriesData.u32(at: row + 16))
            let name = stringTable.string(at: nameOffset) ?? ""

            if name.isEmpty {
                report.issues.append(.init(severity: .warning, title: "条目 \(index) 名称为空", detail: "表项名称偏移 \(nameOffset) 处没有字符串。"))
                continue
            }
            if !seen.insert(name).inserted {
                report.issues.append(.init(severity: .warning, title: "重复条目名", detail: "“\(name)” 在目录里出现多次，安装器可能只取第一个。"))
            }
            if entryOffset < 0 || size < 0 {
                report.issues.append(.init(severity: .blocking, title: "条目偏移或大小非法", detail: "“\(name)” 声明偏移 \(entryOffset)、大小 \(size)。"))
                continue
            }
            let absolute = dataStart + entryOffset
            if absolute + size > reader.size {
                report.issues.append(.init(severity: .blocking, title: "数据越界", detail: "“\(name)” 需要读到 \(absolute + size)，但文件只有 \(reader.size) 字节。文件被截断或表项损坏。"))
                continue
            }
            ranges.append((absolute, size, name))
            report.entries.append(ContainerEntry(name: name, offset: entryOffset, size: size, absoluteOffset: absolute))

            let lower = name.lowercased()
            if lower.hasSuffix(".nca") || lower.hasSuffix(".nca.zs") { report.ncaCount += 1 }
            if lower.hasSuffix(".cnmt.nca") { report.hasCnmt = true }
            if lower.hasSuffix(".tik") || lower.hasSuffix(".ticket") { report.hasTicket = true }
            if lower.hasSuffix(".cert") || lower.hasSuffix(".certificate") { report.hasCertificate = true }

            // One 4-byte probe per NCA is enough to spot zstd-compressed NCZ
            // payloads; we do not read the payload itself.
            if lower.hasSuffix(".nca"), !report.compressedContent, size >= 4 {
                if let probe = try? reader.read(at: absolute, count: 4),
                   probe.string(at: 0, length: 4) == "NCZS" {
                    report.compressedContent = true
                }
            }
        }

        // Overlap detection matters: overlapping ranges make a file look
        // complete to a naive size check while installation reads garbage.
        let sorted = ranges.sorted { $0.0 < $1.0 }
        for (previous, current) in zip(sorted, sorted.dropFirst()) {
            if current.0 < previous.0 + previous.1 {
                let a = ByteCountFormatter.string(fromByteCount: previous.1, countStyle: .file)
                report.issues.append(.init(
                    severity: .blocking,
                    title: "条目数据重叠",
                    detail: "“\(previous.2)”(\(a)) 与 “\(current.2)” 的数据区互相覆盖，容器表已损坏。"))
                break
            }
        }
    }

    /// Checks every container format needs, once entries are known.
    private static func evaluateCommon(report: inout ContainerReport, reader: RandomAccessReader) {
        if report.ncaCount == 0 {
            report.issues.append(.init(
                severity: .blocking,
                title: "没有 NCA 内容",
                detail: "容器里一个 .nca 都没有；DBI 无从安装。可能是空包或只是改了扩展名。"))
        }
        if !report.hasCnmt {
            // DBI cannot install a package without a CNMT: it carries the title
            // ID, version and the content list it has to write. Calling this a
            // warning was wrong — it is a hard stop, same as DBI's red.
            report.issues.append(.init(severity: .blocking, title: "缺少 CNMT",
                                       detail: "没有找到 .cnmt.nca。CNMT 是安装的元数据（标题 ID、版本、内容清单），DBI 缺它无法安装，所以这里按红色处理。"))
        }
        if !report.hasTicket {
            // 缺 ticket 只是本机核对不到签名/授权，证据不足；它不等于签名非官方
            // （实机对照：无 ticket 的零售 XCI 在 DBI 逐 NCA 验签仍可全 OK）。
            // 真·签名非官方由深度检查 signatureInvalid 判定并升级为 caution。
            report.issues.append(.init(severity: .note, title: "未携带 ticket",
                                       detail: "包内没有 .tik，本机无法核对签名与授权；这不等于签名非官方，最终以 DBI 实机安装结果为准。"))
        }
        if report.compressedContent {
            // Not a DBI yellow: DBI decompresses NSZ itself and will happily
            // show green. Our inability to look inside is *our* uncertainty,
            // so this must not borrow the "non-retail" colour.
            report.issues.append(.init(
                severity: .note,
                title: "压缩内容 (NCZ)",
                detail: "NCA 内部是 zstd 压缩的 NCZ。快速检查只能验证外层容器；签名与哈希要先解压才能验证，所以本机标为“未验签”，不等于 DBI 的黄色。"))
        }
    }

    // MARK: - Verdict

    private static func verdict(for report: ContainerReport) -> PackageVerdict {
        if report.issues.contains(where: { $0.severity == .blocking }) { return .blocked }
        if report.issues.contains(where: { $0.severity == .warning }) { return .caution }
        // A structurally clean package is still unverified: the quick pass
        // never touches signatures, so it cannot claim DBI's green.
        return .unverified
    }

    // MARK: - Title ID / version / type

    /// Extracts the title ID from NCA/ticket names.
    ///
    /// The CNMT is authoritative: its name is exactly `<title id>.cnmt.nca`.
    /// Ticket and NCA names hold content IDs, which merely *look* like title
    /// IDs, so they are only a fallback and never override a CNMT hit.
    static func titleIDFrom(names: [String]) -> String? {
        func firstMatch(_ pattern: String, in names: [String]) -> String? {
            for name in names {
                if let id = firstCapture(pattern: pattern, in: name) {
                    let upper = id.uppercased()
                    if isValidTitleID(upper) { return upper }
                }
            }
            return nil
        }
        if let id = firstMatch(#"([0-9A-Fa-f]{16})\.cnmt\.nca"#, in: names) { return id }
        // A ticket is named `<title id><16 zeros>.tik`, so 32 hex digits: take
        // the leading title ID. Requiring exactly 16 digits here used to fail
        // on every real ticket, which is why whole libraries came back with no
        // title ID at all.
        if let id = firstMatch(#"([0-9A-Fa-f]{16})[0-9A-Fa-f]{0,16}\.tik"#, in: names) { return id }
        return nil
    }

    /// Last resort: the release-name bracket, e.g.
    /// `[本体v1.0.0][01000000000DD000][16.0.3][中文].nsp`. Cartridge images
    /// carry no ticket at all, and repacks often hash the CNMT name, so without
    /// this an XCI would stay unidentified.
    static func titleIDFromFileName(_ fileName: String) -> String? {
        for match in matches(pattern: #"\[([0-9A-Fa-f]{16})\]"#, in: fileName) {
            let upper = match.uppercased()
            if isValidTitleID(upper) { return upper }
        }
        return nil
    }

    /// Retail title IDs put the content type in the low bits, and the four
    /// digits before `.cnmt.nca` are *not* always `0000`:
    ///
    ///   `<Y>000` with an even Y -> application (Sample Game is
    ///   `01000000000AA000`, another retail title is `01000000000BA000`)
    ///   `<Y>800`                -> patch for the same application
    ///   `<Y>XXX` with an odd Y  -> add-on content #XXX (`base | 0x1000`)
    ///
    /// Comparing only against 0x0000/0x0800 therefore sent almost every
    /// retail base title and its update down the "DLC" branch, because their
    /// low 16 bits read 0x2000, 0xA000, 0x6000 … instead of 0x0000.
    static func contentType(for titleID: String, fileName: String) -> PackageContentType {
        guard let value = UInt64(titleID, radix: 16) else { return .unknown }
        let suffix = value & 0xFFFF
        // Bit 12 set means an odd Y digit, i.e. add-on content.
        if suffix & 0x1000 != 0 { return .dlc }
        let low = suffix & 0x0FFF
        if low == 0x0800 { return .update }
        if low == 0x0000 { return .base }
        return .dlc
    }

    /// True when a 16-hex token looks like a title ID rather than a content
    /// ID. Some repacked/CDN containers name their CNMT after a content
    /// hash; treating that as a title ID would invent a bogus group and a
    /// bogus content type.
    static func isValidTitleID(_ candidate: String) -> Bool {
        guard candidate.count == 16, let value = UInt64(candidate, radix: 16) else { return false }
        let prefix = UInt16(truncatingIfNeeded: value >> 48)
        return prefix == 0x0100 || prefix == 0x0400 || (0x0500...0x05FF).contains(prefix)
    }

    static func contentTypeFromName(_ name: String) -> PackageContentType {
        let lower = name.lowercased()
        if lower.contains("dlc") || lower.contains("addon") || lower.contains("add-on") { return .dlc }
        if lower.contains("update") || lower.contains("patch") || lower.contains("更新") { return .update }
        return .unknown
    }

    static func versionFromName(_ name: String) -> Int? {
        let patterns = [#"\[v(\d{1,10})\]"#, #"\(v(\d{1,10})\)"#, #" v(\d{3,10})"#, #"[_ ]v(\d{1,7})"#]
        for pattern in patterns {
            if let value = firstCapture(pattern: pattern, in: name, caseInsensitive: true),
               let number = Int(value) {
                return number
            }
        }
        return nil
    }

    private static func firstCapture(pattern: String, in text: String, caseInsensitive: Bool = false) -> String? {
        matches(pattern: pattern, in: text, caseInsensitive: caseInsensitive).first
    }

    private static func matches(pattern: String, in text: String, caseInsensitive: Bool = false) -> [String] {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1, let captured = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[captured])
        }
    }

    // MARK: - Helpers

    static func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile != false, let size = values.fileSize else {
            throw NSError(domain: "PackageInspector", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "不是普通文件"])
        }
        return Int64(size)
    }

    /// Turns a file/folder name into something worth showing in a list.
    ///
    /// Release naming is noisy in a very consistent way: `[本体v1.0.0]`,
    /// `[01000000000AA000]`, `[中文]`, `[US]`, `(0.41 GB)`, `v1.0.0`, `.nsp`.
    /// Every one of those is stripped; whatever survives is the game's name.
    /// When nothing survives (*"升级档-v1.1.0"*, *"nsz本体"*) the enclosing
    /// folders are walked instead, because that is where a dump keeps the real
    /// title — `SampleGame/DLC` only says "DLC", its parent says the game.
    /// Nothing computed here is used to decide validity.
    static func displayName(for url: URL) -> String {
        let stem = cleanedName(url.deletingPathExtension().lastPathComponent)
        if !stem.isEmpty, !isGenericName(stem) { return stem }
        if let folder = meaningfulFolderName(for: url) { return folder }
        if !stem.isEmpty { return stem }
        return folderName(for: url)
    }

    /// Strips release tags. Only cosmetic: never removes letters or digits that
    /// belong to a real title (`Super Mario 3D World` keeps its 3D).
    static func cleanedName(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(of: #"\[[^\[\]]*\]"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\([^\(\)]*\)"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"（[^（）]*）"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"【[^【】]*】"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\b[0-9A-Fa-f]{16}\b"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\bv\d+(?:[._]\d+)*\b"#, with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"[._]"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[-–—_]"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }

    /// Folder/release words that name a *kind* of content, not a game.
    private static let genericNames: Set<String> = [
        "base", "game", "games", "main", "title", "tit", "rom", "program", "app", "content",
        "dlc", "dlcs", "addon", "addons", "add-on", "update", "updates", "patch", "patches",
        "upd", "nsp", "nsz", "xci", "xcz", "files", "data", "download", "downloads",
        "switch", "switch games", "switch game", "games", "untitled", "untitled folder",
        "new folder", "folder", "roms",
        "游戏", "本体", "游戏本体", "安装包", "安装文件", "新建文件夹", "下载", "switch游戏",
        "switch游戏安装包", "switch游戏安装包文件夹", "升级档", "升级补丁", "更新档", "补丁", "更新",
        "dlc文件"
    ]

    /// True when a name carries no game title of its own.
    static func isGenericName(_ raw: String) -> Bool {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.isEmpty || name.count <= 2 { return true }
        if genericNames.contains(name) { return true }
        if let first = name.split(separator: " ").first.map(String.init), genericNames.contains(first) { return true }
        for prefix in ["升级档", "升級檔", "升级补丁", "更新档", "本体", "游戏本体", "dlc", "update", "patch", "addon", "nsz本体", "nsp本体"] {
            if name.hasPrefix(prefix) { return true }
        }
        return false
    }

    /// Walks up from the file until a folder with a real title is found. Stops
    /// before the volume itself so a package sitting in the library root does
    /// not end up named "Data".
    private static func meaningfulFolderName(for url: URL) -> String? {
        var directory = url.deletingLastPathComponent()
        var depth = 0
        while depth < 6 {
            let path = directory.standardizedFileURL.path
            if path == "/" || directory.pathComponents.count <= 2 { break }
            if directory.deletingLastPathComponent().pathComponents.count <= 2 { break }
            let name = cleanedName(directory.lastPathComponent)
            if !name.isEmpty, !isGenericName(name) { return name }
            directory = directory.deletingLastPathComponent()
            depth += 1
        }
        return nil
    }

    /// The folder a package was found in, used to name an unidentified group.
    static func folderName(for url: URL) -> String {
        let parent = url.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? url.deletingLastPathComponent().path : parent
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.localizedDescription) (\(ns.domain) \(ns.code))"
    }
}

// MARK: - Bounded random-access reader

/// Wraps `FileHandle` with offset-based reads that never load more than asked.
/// FileHandle is not thread-safe; each reader is owned by one scan worker.
private final class RandomAccessReader {
    let size: Int64
    private let handle: FileHandle

    init(url: URL, size: Int64) throws {
        self.handle = try FileHandle(forReadingFrom: url)
        self.size = size
    }

    deinit {
        try? handle.close()
    }

    func read(at offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, offset < size, count > 0 else { return Data() }
        let bounded = Int(min(Int64(count), size - offset))
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: bounded) else { return Data() }
        return data
    }
}

// MARK: - Little-endian helpers

private extension Data {
    func u32(at offset: Int) -> UInt32 {
        guard count >= offset + 4 else { return 0 }
        let base = startIndex + offset
        return UInt32(self[base])
            | (UInt32(self[base + 1]) << 8)
            | (UInt32(self[base + 2]) << 16)
            | (UInt32(self[base + 3]) << 24)
    }

    func u64(at offset: Int) -> UInt64 {
        guard count >= offset + 8 else { return 0 }
        let low = UInt64(u32(at: offset))
        let high = UInt64(u32(at: offset + 4))
        return low | (high << 32)
    }

    func string(at offset: Int, length: Int) -> String? {
        guard offset >= 0, offset + length <= count else { return nil }
        let base = startIndex + offset
        let bytes = self[base..<(base + length)]
        return String(bytes: bytes, encoding: .utf8)
    }

    /// Reads a NUL-terminated string starting at a byte offset.
    func string(at offset: Int) -> String? {
        guard offset >= 0, offset < count else { return nil }
        let base = startIndex + offset
        var end = base
        while end < endIndex, self[end] != 0 { end += 1 }
        let bytes = self[base..<end]
        return String(bytes: bytes, encoding: .utf8)
    }
}
