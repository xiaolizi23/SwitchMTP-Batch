// SwitchMTP Batch — a macOS MTP client for Nintendo Switch running DBI.
// Copyright (C) 2025 fratei
//
// This program is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License version 2 as published by
// the Free Software Foundation.

// Deep verification: the optional second pass that actually looks inside NCAs.
//
// hactool (ISC licence, built into the app bundle) does the cryptography: it
// decrypts NCA headers with the user's own prod.keys, registers the title keys
// carried by the package's own tickets, checks the RSA signature chain and the
// content hashes, and reports GOOD/FAIL per item.
//
// The bundled hactool was patched so that `-t nsp` walks the PFS0 table and
// verifies each .nca **in place**: before that, `-y -t pfs0` only listed the
// container and could never say anything about signatures, which is why the
// old deep check reported "无结论" on every real NSP.
//
// Output contract (see nsp.c):
//   NSP_NCA_BEGIN: <entry>
//   ...hactool's per-NCA print (signature, key revision, hash verdicts)...
//   NSP_NCA_END: <entry>
//   NSP_RESULT: <n> nca(s), <m> skipped

import Foundation

enum DeepVerifier {

    static let executableName = "hactool"

    /// Located in `Contents/Resources/bin`, with an environment override so a
    /// development build can point at a freshly compiled binary.
    static var hactoolURL: URL? {
        if let override = ProcessInfo.processInfo.environment["SWITCHMTP_HACTOOL"],
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        let candidates: [URL?] = [
            Bundle.main.url(forResource: executableName, withExtension: nil, subdirectory: "bin"),
            Bundle.main.url(forResource: executableName, withExtension: nil),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin/\(executableName)")
        ]
        for candidate in candidates {
            if let url = candidate, FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    /// One NCA inside the package, as far as the engine got.
    struct NCACheck: Identifiable, Sendable, Hashable {
        enum Verdict: String, Sendable {
            case good, fail, unknown
        }
        let id = UUID()
        let name: String
        var signature: Verdict = .unknown
        var hash: Verdict = .unknown
        var keyRevision: String?
        var note: String?
        var isTitleKeyMissing = false
        /// The engine reported this NCA's generation as one its keyname table
        /// does not know ("0x11 (Unknown)"). Only used to explain a missing
        /// verdict; a decrypted-and-verified NCA is judged on its merits.
        var unknownKeyGeneration = false
        /// The engine's own section/table hashes disagreed with the data.
        var hardHashFail = false
        /// Only IVFC level tables disagreed; unreliable on huge RomFS images.
        var levelHashFail = false
        /// Downgraded from a level-table failure: the engine cannot vouch for
        /// the content, so this must never be presented as a full pass.
        var contentUnconfirmed = false
        /// A BKTR patch section is deliberately not walked without the base
        /// RomFS, so this NCA's "hash good" only covers its other sections.
        var partialHash = false
        /// Which IVFC levels disagreed (1-based, as the engine prints them),
        /// so the note can say "only level 4" instead of "the RomFS is off".
        var failedLevels: [Int] = []

        var signatureText: String {
            switch signature {
            case .good: return "签名 ✓"
            case .fail: return "签名 ✗"
            case .unknown: return "签名 —"
            }
        }

        var hashText: String {
            if isTitleKeyMissing { return "哈希 无密钥" }
            switch hash {
            case .good: return "哈希 ✓"
            case .fail: return "哈希 ✗"
            case .unknown: return "哈希 —"
            }
        }
    }

    /// Checks one package. Always returns a state, never throws: a check that
    /// could not run is "unavailable" — which must never be dressed up as a
    /// pass, because that is exactly how a green row turned yellow on the
    /// console.
    ///
    /// `progress` carries a 0...1 fraction plus a short stage label. The
    /// fraction is computed from real engine markers (NCAs finished / total
    /// NCAs; entries unpacked / total entries), so a row never shows a
    /// invented "almost there" bar.
    static func verify(url: URL,
                       format: PackageFormat,
                       keysetURL: URL,
                       titleKeysURL: URL? = nil,
                       hactoolURL: URL,
                       expectedNCAs: Int? = nil,
                       entrySizes: [String: Int64] = [:],
                       progress: ((Double, String) -> Void)? = nil) -> DeepResult {
        // NSZ is now unpacked (zstd + section re-encryption) into a temporary
        // NSP, whose NCAs are then verified exactly like a normal NSP. The
        // rebuilt NCAs are also hashed against the package's own CNMT XML,
        // which is the same evidence DBI checks on the console.
        if format == .nsz {
            return verifyNSZ(url: url, keysetURL: keysetURL,
                             titleKeysURL: titleKeysURL, hactoolURL: hactoolURL,
                             expectedNCAs: expectedNCAs, progress: progress)
        }
        if format == .xcz {
            return DeepResult(state: .unavailable, notes: [
                .init(severity: .warning, title: "XCZ 仍需专用解包",
                      detail: "Sparse/块压缩的卡带镜像（XCZ）内部是 HFS0 分区，本版的解包器只处理 NSZ 的 NCZ 内容，XCZ 目前只验到容器头。签名与哈希位于分区内的 NCA 里，因此只能说“外层结构正常、签名未验证”。")
            ], detail: "XCZ 尚未支持解包")
        }

        // NSP and XCI are both walked NCA by NCA by the patched engine. XCZ
        // still needs its own unpacker (see above).
        guard format == .nsp || format == .xci else {
            return DeepResult(state: .unavailable, notes: [
                .init(severity: .note, title: "该格式尚未做逐 NCA 验签",
                      detail: "当前引擎只能对 NSP / XCI 逐个 NCA 验签名与哈希。\(format.displayName) 只验到容器头，结论等于“未验签”，不等于 DBI 的绿色。")
            ], detail: "格式未支持逐 NCA 验签")
        }

        var arguments = ["-i", "-y", "--disablekeywarns", "--suppresskeys", "-k", keysetURL.path]
        if let titleKeysURL {
            arguments += ["--titlekeys", titleKeysURL.path]
        }
        let intype: String = (format == .xci) ? "xci" : "nsp"
        arguments += ["-t", intype, url.path]

        var begunNCAs = 0
        var finishedNCAs = 0
        var doneBytes: Int64 = 0
        let totalBytes = entrySizes.values.reduce(Int64(0), +)
        let output: String
        switch run(hactoolURL, arguments: arguments, timeout: 1800, onLine: { line in
            if line.hasPrefix("NSP_NCA_BEGIN:") {
                begunNCAs += 1
            } else if line.hasPrefix("NSP_NCA_END:") {
                finishedNCAs += 1
                let name = line.dropFirst("NSP_NCA_END:".count)
                    .trimmingCharacters(in: .whitespaces)
                if let size = entrySizes[name] { doneBytes += size }
                // Weight by NCA size: a KB-sized CNMT and a multi-GB RomFS NCA
                // are not equal units, so a plain count jumps after tiny files
                // and stalls on the big one. Fall back to counting when the
                // structural pass has no entry sizes.
                let fraction: Double
                if totalBytes > 0 {
                    fraction = min(Double(doneBytes) / Double(totalBytes), 1)
                } else {
                    let total = expectedNCAs ?? max(begunNCAs, 1)
                    fraction = min(Double(finishedNCAs) / Double(max(total, 1)), 1)
                }
                progress?(fraction, "验签中")
            }
        }) {
        case .failure(let message):
            return DeepResult(state: .unavailable, notes: [
                .init(severity: .warning, title: "校验引擎未能运行", detail: message)
            ], detail: message)
        case .success(let text):
            output = text
        }

        var result = interpret(output: output, format: format)
        result.displayVersion = NacpVersionReader.displayVersion(
            url: url, format: format, keysetURL: keysetURL,
            titleKeysURL: titleKeysURL, hactoolURL: hactoolURL)
        return result
    }

    // MARK: - NSZ

    /// Unpacks an NSZ and verifies the result. Kept separate from `verify`
    /// because it has two sources of truth to reconcile:
    ///
    ///  * hactool on the rebuilt NSP — signatures, and hashes where it can
    ///    derive the title key;
    ///  * `NSZ_HASH` — SHA-256 of every rebuilt NCA against the package's own
    ///    CNMT XML. That is byte-exact evidence: if it matches, the container
    ///    holds exactly the content the publisher signed, no matter what a
    ///    tool's own section walk thinks.
    static func verifyNSZ(url: URL, keysetURL: URL, titleKeysURL: URL?, hactoolURL: URL,
                          expectedNCAs: Int? = nil,
                          progress: ((Double, String) -> Void)? = nil) -> DeepResult {
        guard let tool = NSZUnpacker.toolURL else {
            return DeepResult(state: .unavailable, notes: [
                .init(severity: .warning, title: "缺少 NSZ 解包工具",
                      detail: "应用包内没有 nszunpack，无法把 NSZ 解开后校验。重新构建或使用完整的发布包。")
            ], detail: "NSZ 解包工具缺失")
        }

        // Stage split: unpacking is the slow half for a compressed title, so it
        // owns the first 60% of the bar; the rebuilt NSP's per-NCA signature
        // walk owns the remaining 40%.
        var unpackTotal = 0
        var unpackedEntries = 0
        let conversion: NSZUnpacker.Conversion
        do {
            conversion = try NSZUnpacker.unpack(
                url: url,
                to: NSZUnpacker.scratchURL(named: url.deletingPathExtension().lastPathComponent),
                tool: tool,
                onLine: { line in
                    if line.hasPrefix("NSZ_ENTRIES:") {
                        let payload = line.dropFirst("NSZ_ENTRIES:".count)
                            .trimmingCharacters(in: .whitespaces)
                        unpackTotal = Int(payload) ?? unpackTotal
                    } else if line.hasPrefix("NSZ_PROGRESS:") {
                        unpackedEntries += 1
                        let fraction = min(Double(unpackedEntries) / Double(max(unpackTotal, 1)), 1)
                        progress?(0.6 * fraction, "解包中")
                    }
                })
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return DeepResult(state: .unavailable, notes: [
                .init(severity: .warning, title: "NSZ 解包失败",
                      detail: "\(message)\n这不是“文件没问题”的结论：解不开就无法验签，本项按未验签处理。")
            ], detail: message)
        }
        defer { NSZUnpacker.discard(conversion.outputURL) }

        let innerExpected = expectedNCAs ?? conversion.hashes.count
        let inner = verify(url: conversion.outputURL, format: .nsp,
                           keysetURL: keysetURL, titleKeysURL: titleKeysURL,
                           hactoolURL: hactoolURL,
                           expectedNCAs: innerExpected,
                           progress: { fraction, _ in
                               progress?(0.6 + 0.4 * fraction, "验签中")
                           })
        var result = reconcileNSZ(inner: inner, conversion: conversion, source: url)
        // The rebuilt inner NSP was already read for its Control NCA; carry that
        // display version through instead of re-decrypting the NSZ again.
        result.displayVersion = inner.displayVersion
        return result
    }


    /// Merges hactool's per-NCA verdicts with the CNMT hash proof.
    static func reconcileNSZ(inner: DeepResult, conversion: NSZUnpacker.Conversion, source: URL) -> DeepResult {
        var checks = inner.ncas
        let hashesByID = Dictionary(conversion.hashes.map { ($0.contentID, $0) }, uniquingKeysWith: { first, _ in first })

        for index in checks.indices {
            guard let proof = hashesByID[String(checks[index].name.prefix(32)).lowercased()] else { continue }
            switch proof.match {
            case .yes:
                // Byte-identical to what the CNMT declares, so any "hash fail"
                // left by the tool's own section walk is the tool's problem,
                // not the file's.
                checks[index].hash = .good
                checks[index].isTitleKeyMissing = false
            case .no:
                checks[index].hash = .fail
                checks[index].note = "解包后 SHA-256 与 CNMT 清单不符（\(proof.sha256.prefix(12))… ≠ \(proof.expected?.prefix(12) ?? "?")…）"
            case .unknown:
                break
            }
        }
        if checks.isEmpty {
            for proof in conversion.hashes {
                var check = NCACheck(name: proof.ncaName)
                check.hash = proof.match == .yes ? .good : (proof.match == .no ? .fail : .unknown)
                checks.append(check)
            }
        }

        var notes: [CheckNote] = []
        notes.append(.init(severity: .note, title: "NSZ 已解包后校验",
                           detail: "已用内置解包器把 NCZ 还原成 NCA 并写回 NSP（\(conversion.entries) 个条目，用时 "
                               + String(format: "%.1f", conversion.duration) + " 秒）。\(conversion.summaryText)。"))
        if conversion.mismatchedCount > 0 {
            notes.append(.init(severity: .blocking, title: "解包结果与清单不符",
                               detail: "\(conversion.mismatchedCount) 个 NCA 的 SHA-256 与包内 CNMT 声明的哈希不同：压缩流损坏或包被改写过。DBI 装到这一层会失败，对应红色。"))
        }
        // hactool ran on the rebuilt NSP and can only see its own section walk;
        // a hash "fail" it produced there is already resolved (or confirmed) by
        // the CNMT proof above, so its hash/signature summaries must not leak
        // through as contradictory advice.
        let stale = ["内容哈希不符", "签名非官方", "签名与哈希通过", "签名通过，内容哈希未验证", "只拿到部分结论"]
        notes.append(contentsOf: inner.notes.filter { note in
            // The unconfirmed note is re-inserted below with the flagged NCA
            // named explicitly; keep one copy instead of duplicating it.
            note.title != "内容无法确认"
            && !stale.contains { note.title.contains($0) }
        })

        if let unconfirmed = inner.ncas.first(where: { $0.contentUnconfirmed }) {
            notes.insert(.init(severity: .warning, title: "内容无法确认",
                               detail: "包内没有 CNMT 清单，而引擎在 \(unconfirmed.name) 的 RomFS 层级表上报了不一致"
                                   + levelDetail(unconfirmed)
                                   + "。签名成立，但内容是否逐字节完整无法判定；建议按 DBI 实际安装结果为准（DBI 只验签，不看内容哈希，它能装不代表内容没改过）。"), at: 1)
            return DeepResult(state: .unavailable, notes: notes, detail: "内容无法确认", ncas: checks)
        }

        let sigFails = checks.filter { $0.signature == .fail }
        let sigGoods = checks.filter { $0.signature == .good }
        let hashFails = checks.filter { $0.hash == .fail }
        let hashGoods = checks.filter { $0.hash == .good }
        _ = source

        if !hashFails.isEmpty {
            return DeepResult(state: .failed, notes: notes,
                              detail: "\(hashFails[0].name) 内容不符", ncas: checks)
        }
        if !sigFails.isEmpty {
            notes.insert(.init(severity: .warning, title: "签名非官方（对应 DBI 黄色）",
                               detail: "解包后的 NCA 内容完整，但 RSA 签名不是零售链签发的。DBI 装完会显示黄色，需要 sigpatch。\(sigFails.count)/\(checks.count) 个 NCA 签名不通过。"), at: 1)
            return DeepResult(state: .signatureInvalid, notes: notes,
                              detail: "\(sigFails[0].name) 签名非官方", ncas: checks)
        }
        let proofText = conversion.matchedCount > 0
            ? "其中 \(conversion.matchedCount) 个 NCA 的 SHA-256 与 CNMT 清单逐字节一致"
            : "内容哈希由引擎在解包后的 NSP 上校验通过（包内没有 CNMT XML 可对照）"
        if checks.isEmpty || sigGoods.count < checks.count {
            let anyHash = hashGoods.isEmpty ? "内容哈希也没有结论" : "已有 \(hashGoods.count) 个 NCA 的哈希通过"
            notes.insert(.init(severity: .warning, title: "签名未全部验证",
                               detail: "\(checks.count) 个 NCA 中有 \(sigGoods.count) 个签名通过；其余未能判定（多为密钥代不足）。\(anyHash)，但仍不等于 DBI 完整校验的绿。"), at: 1)
            return DeepResult(state: .unavailable, notes: notes, detail: "签名未全部验证", ncas: checks)
        }
        if hashGoods.isEmpty {
            notes.insert(.init(severity: .note, title: "签名通过，内容哈希未验证",
                               detail: "\(sigGoods.count) 个 NCA 的零售签名全部成立，但没有可用的内容哈希结论。这比“未验签”强，但仍不等于 DBI 完整校验的绿。"), at: 1)
            return DeepResult(state: .signatureOnly, notes: notes, detail: "解包后签名通过 · 哈希未验", ncas: checks)
        }
        notes.insert(.init(severity: .note, title: "签名与哈希通过（对应 DBI 绿）",
                           detail: "\(sigGoods.count) 个 NCA 的零售签名全部成立，\(proofText)。"), at: 1)
        return DeepResult(state: .verified, notes: notes, detail: "解包后签名与哈希通过", ncas: checks)
    }

    // MARK: - Output interpretation

    /// hactool exits 0 even when every signature fails, so the exit status is
    /// worthless here and the text is the whole signal.
    static func interpret(output: String, format: PackageFormat) -> DeepResult {
        let lower = output.lowercased()

        // 1. Structural failures at container level — nothing inside can be
        //    trusted after these.
        let containerFailures = ["nsp is corrupt", "failed to read nsp", "not a pfs0 container",
                                 "bad file count", "tables unreadable"]
        if containerFailures.contains(where: { lower.contains($0) }) {
            return DeepResult(state: .failed, notes: [
                .init(severity: .blocking, title: "容器结构损坏",
                      detail: "引擎连 PFS0 表都读不出来。DBI 装这类包同样会失败，对应红色。")
            ], detail: firstInterestingLine(output) ?? "容器损坏")
        }

        let checks = parseNCABlocks(output)
        guard !checks.isEmpty else {
            let keyGap = lower.contains("are keys correct") || lower.contains("unable to match rights id")
            if keyGap {
                return DeepResult(state: .unavailable, notes: [
                    .init(severity: .warning, title: "密钥不足，未能验证任何 NCA",
                          detail: "引擎报告无法解密 NCA 头。通常是 prod.keys 缺少较新的密钥代。结果只能算“未验签”，不等于文件有问题。")
                ], detail: "密钥不足")
            }
            return DeepResult(state: .unavailable, notes: [
                .init(severity: .warning, title: "未得到可判定的校验结果",
                      detail: firstInterestingLine(output).map { "引擎没有输出任何 NCA 结论：\($0)" }
                          ?? "引擎没有输出任何 NCA 结论。可能是包结构非常规，或输入类型与内容不符。")
            ], detail: "无结论")
        }

        let signatureFails = checks.filter { $0.signature == .fail }
        let signatureGoods = checks.filter { $0.signature == .good }
        let hashFails = checks.filter { $0.hash == .fail && !$0.isTitleKeyMissing }
        let hashGoods = checks.filter { $0.hash == .good }
        let keyGaps = checks.filter { $0.isTitleKeyMissing }
        let unknowns = checks.filter { $0.signature == .unknown && !$0.isTitleKeyMissing }

        // The engine tells us whether it managed to derive any title key at all.
        // Without a key, hash mismatches are an artefact of not decrypting — not
        // proof of a bad package. (RE1 retail sample: 3/4 NCAs hash GOOD once the
        // ticket key is derived, which is how this distinction was calibrated.)
        let registeredKeys = Self.markerValue("NSP_KEYSTATE", field: "registered", in: output) ?? 1

        // A hash failure only counts as "confirmed corruption" when the key was
        // settled and the NCA's own key generation is known. If the generation
        // is unknown, or the package as a whole could not derive its title keys,
        // a FAIL reads as "could not decrypt / engine walk unreliable" and must
        // stay off the red verdict — it is "cannot confirm", not "content bad".
        let packageKeyGap = !keyGaps.isEmpty || registeredKeys == 0
        let confirmedBad = hashFails.filter { nca in
            !nca.unknownKeyGeneration && !(packageKeyGap && nca.signature == .good)
        }
        let suspectFails = hashFails.filter { !confirmedBad.contains($0) }

        // 2a. Confirmed content mismatch: DBI would fail to install it. Red.
        if !confirmedBad.isEmpty {
            return DeepResult(state: .failed, notes: [
                .init(severity: .blocking, title: "签名保留、内容哈希不符（DBI 会安装失败）",
                      detail: "NCA 头签名是真的、密钥代已确认，但解出来的内容与清单哈希对不上：典型特征是该 NCA 被替换、重打包不完整或传输损坏。DBI 装到这一层会报错，对应红色。")
            ], detail: "\(confirmedBad[0].name) 哈希校验失败", ncas: checks)
        }

        // 2b. Hash FAIL riding on an unresolved key: cannot confirm, never red.
        if !suspectFails.isEmpty {
            return DeepResult(state: .unavailable, notes: [
                .init(severity: .warning, title: "哈希存疑，暂不判损坏",
                      detail: "\(suspectFails[0].name) 的哈希校验未通过，但伴随密钥代未知或整包标题密钥未派生；FAIL 可能源于解密偏差或引擎遍历不可靠，不能据此判定内容损坏。最终以 DBI 实机安装结果为准。")
            ], detail: "哈希存疑", ncas: checks)
        }

        // 3. Signature actually checked and not retail — DBI's yellow.
        if let first = signatureFails.first {
            return DeepResult(state: .signatureInvalid, notes: [
                .init(severity: .warning, title: "签名非官方（对应 DBI 黄色）",
                      detail: "结构完整、内容可读，但 RSA 签名不是任天堂零售链签发的。这正是装完后 DBI 显示黄色的情况：能装，需要 sigpatch，但不是原版。共 \(signatureFails.count)/\(checks.count) 个 NCA 签名不通过。")
            ], detail: "\(first.name) 签名非官方", ncas: checks)
        }

        // 4. Keys were missing for some entries: signature may be fine, hash
        //    cannot be judged. Never call that a pass.
        if !keyGaps.isEmpty || !unknowns.isEmpty {
            var notes: [CheckNote] = [
                .init(severity: .warning, title: "部分 NCA 无法验证",
                      detail: "\(keyGaps.count) 个 NCA 缺少 title key，\(unknowns.count) 个 NCA 没能读出结论。这些条目的哈希无法判定；已通过签名的条目仍然可信。")
            ]
            if !signatureGoods.isEmpty {
                notes.append(.init(severity: .note, title: "已通过部分",
                                   detail: "\(signatureGoods.count)/\(checks.count) 个 NCA 签名确认是零售签名。"))
            }
            return DeepResult(state: .unavailable, notes: notes, detail: "部分 NCA 未验证", ncas: checks)
        }

        // 5. Every signature checked out, but content hashes could not be
        //    computed anywhere: signature-level pass only. If not a single
        //    signature was actually read, this is "no conclusion", not a pass.
        if hashGoods.isEmpty {
            guard signatureGoods.count == checks.count else {
                return DeepResult(state: .unavailable, notes: [
                    .init(severity: .warning, title: "只拿到部分结论",
                          detail: "\(checks.count) 个 NCA 中只有 \(signatureGoods.count) 个签名通过，其余未能判定。结果按“未验签”处理。")
                ], detail: "部分 NCA 未验证", ncas: checks)
            }
            return DeepResult(state: .signatureOnly, notes: [
                .init(severity: .note, title: "签名通过，内容哈希未验证",
                      detail: "全部 \(checks.count) 个 NCA 的零售签名成立，但没有可用的内容哈希结论（通常是包内没有 ticket、或解包不完整）。这比“未验签”强，但仍不等于 DBI 完整校验后的绿。")
            ], detail: "签名通过 · 哈希未验", ncas: checks)
        }

        // 5b. The engine itself flagged a RomFS level table but there is no
        //     manifest to settle it. Say "cannot confirm" rather than green.
        if let first = checks.first(where: { $0.contentUnconfirmed }) {
            return DeepResult(state: .unavailable, notes: [
                .init(severity: .warning, title: "内容无法确认",
                      detail: "包内没有 CNMT 清单，而引擎在 \(first.name) 的 RomFS 层级表上报了不一致"
                          + levelDetail(first)
                          + "。签名成立，但内容是否逐字节完整无法判定；建议按 DBI 实际安装结果为准（DBI 只验签，不看内容哈希，它能装不代表内容没改过）。")
            ], detail: "内容无法确认", ncas: checks)
        }

        // 6. Full pass: every NCA signed by retail, hashes verified where they
        //    could be computed, and nothing failed.
        let partials = checks.filter(\.partialHash)
        let fullHashCount = hashGoods.count - partials.count
        var notes: [CheckNote] = [
            .init(severity: .note, title: "签名与哈希通过（对应 DBI 绿）",
                  detail: "\(signatureGoods.count) 个 NCA 的零售签名全部成立，\(max(fullHashCount, 0)) 个 NCA 的内容哈希通过。")
        ]
        if !partials.isEmpty {
            notes.append(.init(severity: .note, title: "补丁分区未做内容遍历",
                               detail: "\(partials.count) 个 NCA 是 BKTR 补丁分区，离线只验到 NCA 头部与其余分区，补丁内容要靠本体对照或实机安装确认。本机 DBI 对这类补丁包的实测结果是逐 NCA 签名 OK。"))
        }
        if hashGoods.count < checks.count {
            notes.append(.init(severity: .note, title: "部分内容哈希未覆盖",
                               detail: "有 \(checks.count - hashGoods.count) 个 NCA 没有哈希结论（多为不含可校验分区），签名仍然有效。"))
        }
        return DeepResult(state: .verified, notes: notes, detail: "签名与哈希通过", ncas: checks)
    }

    /// Splits the engine output into per-NCA records using the markers nsp.c
    /// prints, so a single failing DLC can be told apart from a failing base
    /// title instead of collapsing both into "some line said fail".
    static func parseNCABlocks(_ output: String) -> [NCACheck] {
        var results: [NCACheck] = []
        var current: NCACheck?

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("NSP_NCA_BEGIN:") {
                if let finished = current { results.append(finished) }
                let name = line.replacingOccurrences(of: "NSP_NCA_BEGIN:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                current = NCACheck(name: name)
                continue
            }
            if line.hasPrefix("NSP_NCA_RETRY:") {
                // The engine wrapped this NCA's title key with a different
                // titlekek generation than the ticket claimed; it is re-reading
                // the same NCA with the header's generation, so drop whatever
                // the discarded first attempt produced.
                if var previous = current {
                    let detail = line.replacingOccurrences(of: "NSP_NCA_RETRY:", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    // Only the verdicts of the discarded attempt are dropped;
                    // the fact that a retry happened is real evidence and has
                    // to survive the second pass.
                    previous.signature = .unknown
                    previous.hash = .unknown
                    previous.hardHashFail = false
                    previous.levelHashFail = false
                    previous.contentUnconfirmed = false
                    previous.partialHash = false
                    previous.failedLevels.removeAll()
                    previous.note = "已按内容实际密钥代重验（\(detail)）"
                    current = previous
                }
                continue
            }
            if line.hasPrefix("NSP_NCA_END:") {
                if var finished = current {
                    // A generation prod.keys does not cover leaves the NCA
                    // undecryptable, so a missing verdict means "keys too old",
                    // never "content bad".
                    if finished.unknownKeyGeneration && finished.hash == .unknown && finished.signature == .unknown {
                        finished.isTitleKeyMissing = true
                        let gen = finished.keyRevision?.split(separator: " ").first.map(String.init) ?? "?"
                        finished.note = "本机 prod.keys 不覆盖 \(gen) 代密钥，这个 NCA 无法解密"
                    }
                    results.append(finished)
                }
                current = nil
                continue
            }
            guard var check = current else { continue }
            let lower = line.lowercased()

            if line.hasPrefix("NSP_NCA_ERROR:") {
                check.note = line.replacingOccurrences(of: "NSP_NCA_ERROR:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                check.signature = .unknown
                current = check
                continue
            }
            if lower.contains("fixed-key signature (good)") || lower.hasPrefix("signature (good)") {
                check.signature = .good
            } else if lower.contains("fixed-key signature (fail)") || lower.hasPrefix("signature (fail)") {
                check.signature = .fail
            } else if lower.contains("npdm signature (good)") {
                if check.signature == .unknown { check.signature = .good }
            } else if lower.contains("npdm signature (fail)") {
                check.signature = .fail
            }

            // The engine prints an NCA more than once: an initial pass before
            // the key generation is settled, then the real one. A failure makes
            // the NCA bad; a later "GOOD" line must not paint over it.
            if lower.contains("hash (good)") {
                if check.hash == .unknown { check.hash = .good }
            } else if lower.contains("superblock hash (fail)") || lower.contains("hash table (fail)")
                        || lower.contains("hash mismatch") {
                check.hash = .fail
                check.hardHashFail = true
            } else if lower.contains("level ") && lower.contains("(fail)") {
                // IVFC level tables of very large RomFS images are reported
                // inconsistently by the engine; without a CNMT manifest this
                // is "cannot tell", not "content is broken".
                check.hash = .fail
                check.levelHashFail = true
                if let level = Self.levelNumber(in: line), !check.failedLevels.contains(level) {
                    check.failedLevels.append(level)
                }
            } else if lower.contains("is corrupted") {
                check.hash = .fail
            }

            if lower.contains("invalid bktr layout") {
                check.partialHash = true
                check.note = "BKTR 补丁分区：引擎跳过该分区的内容遍历，签名仍按 NCA 头部验证"
            }

            if lower.contains("unable to match rights id to titlekey") {
                check.isTitleKeyMissing = true
                check.note = "缺少该标题的 title key（包内 ticket 未能补上）"
            } else if lower.contains("are keys correct") || lower.contains("failed to read nca header") {
                check.isTitleKeyMissing = true
                check.note = "NCA 头无法解密（密钥代不足）"
            }

            if line.hasPrefix("Master Key Revision:") {
                check.keyRevision = line.replacingOccurrences(of: "Master Key Revision:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if lower.contains("(unknown)") {
                    check.unknownKeyGeneration = true
                }
            }
            current = check
        }
        if let finished = current { results.append(finished) }
        for i in results.indices where results[i].hash == .fail
            && results[i].levelHashFail && !results[i].hardHashFail {
            results[i].hash = .unknown
            results[i].contentUnconfirmed = true
            let levels = results[i].failedLevels.map(String.init).joined(separator: "、")
            results[i].note = levels.isEmpty
                ? "引擎在 RomFS 层级表上报了不一致，但没有 CNMT 清单可对照，无法判定内容是否完好"
                : "引擎只在 RomFS IVFC Level \(levels) 上报了不一致（其余层级与 Superblock 均通过），但没有 CNMT 清单可对照，无法判定内容是否完好"
        }
        return results
    }

    /// Pulls the IVFC level number out of a line like "Level 4 (FAIL):".
    static func levelNumber(in line: String) -> Int? {
        guard let range = line.range(of: "Level ", options: .caseInsensitive) else { return nil }
        let digits = line[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    /// "（仅 IVFC Level 4，Superblock 与其余层级通过）" — empty when no level
    /// was flagged, so the caller's sentence still reads normally.
    static func levelDetail(_ check: NCACheck) -> String {
        guard !check.failedLevels.isEmpty else { return "" }
        let levels = check.failedLevels.sorted().map(String.init).joined(separator: "、")
        return "（仅 IVFC Level \(levels)，Superblock 与其余层级通过）"
    }

    /// Reads `NAME: key=value ...` marker lines the patched engine prints
    /// (currently only NSP_KEYSTATE) without needing a full parser.
    static func markerValue(_ marker: String, field: String, in output: String) -> Int? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(marker) else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let payload = line[line.index(after: colon)...]
            for part in payload.split(whereSeparator: { $0 == "," || $0 == " " }) {
                let pair = part.split(separator: "=")
                guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces) == field else { continue }
                return Int(pair[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    private static func firstInterestingLine(_ text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.lowercased() != "done!" }
        let noise = ["[warn] prod.keys", "hactool (c)", "built:", "[warn]"]
        return lines.first { line in
            let lower = line.lowercased()
            return !noise.contains { lower.contains($0) }
        }.map { redact($0) }
    }

    /// Defence in depth: even if a future engine echoes a key, it never reaches
    /// the UI or a log.
    private static func redact(_ line: String) -> String {
        line.replacingOccurrences(of: #"\b[0-9A-Fa-f]{32,}\b"#, with: "<已隐藏>", options: .regularExpression)
    }

    // MARK: - Process plumbing

    enum RunOutcome {
        case success(String)
        case failure(String)
    }

    static func run(_ executable: URL, arguments: [String], timeout: TimeInterval,
                    onLine: ((String) -> Void)? = nil) -> RunOutcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // The file-handle monitor thread and the caller thread that drains the
        // output after `waitUntilExit` must never touch the buffered strings at
        // the same time. Before this fix the captured `buffer`/`collected` were
        // mutated from both threads; a COW string refcount race could corrupt the
        // heap and abort with a malloc double free (crash 2026-11-28 11:37).
        let drainQueue = DispatchQueue(label: "me.fratei.switchmtp.deep-verifier.output")
        var buffer = ""
        var collected = ""

        let readHandle = pipe.fileHandleForReading
        readHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            drainQueue.async {
                buffer.append(String(data: data, encoding: .utf8) ?? "")
                while let newline = buffer.firstIndex(of: "\n") {
                    let line = String(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(...newline)
                    collected.append(line + "\n")
                    onLine?(line)
                }
            }
        }

        do {
            try process.run()
        } catch {
            readHandle.readabilityHandler = nil
            drainQueue.sync { }
            try? readHandle.close()
            return .failure(error.localizedDescription)
        }

        let timeoutWork = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

        process.waitUntilExit()
        timeoutWork.cancel()
        readHandle.readabilityHandler = nil

        // No further handler can be enqueued now. Wait for any in-flight
        // callback to finish, pull whatever the pipe still holds, and take the
        // final remainder under the same lock.
        var remainder = ""
        var output = ""
        drainQueue.sync {
            let trailing = readHandle.availableData
            if !trailing.isEmpty {
                buffer.append(String(data: trailing, encoding: .utf8) ?? "")
            }
            remainder = buffer.trimmingCharacters(in: .newlines)
            if !remainder.isEmpty {
                collected.append(remainder)
            }
            output = collected
        }
        if !remainder.isEmpty {
            onLine?(remainder)
        }
        try? readHandle.close()

        if process.terminationStatus != 0, output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure("校验引擎异常退出（\(process.terminationStatus)）")
        }
        return .success(output)
    }
}

struct DeepResult {
    var state: DeepCheckState
    var notes: [CheckNote]
    var detail: String
    var ncas: [DeepVerifier.NCACheck] = []
    /// 主机/DBI 界面显示的点分版本（来自 Control NCA 的 NACP `display_version`），
    /// 与内部 build 号是两套数。DLC 无 Control NCA、或解密失败时为 nil。
    var displayVersion: String? = nil
}
