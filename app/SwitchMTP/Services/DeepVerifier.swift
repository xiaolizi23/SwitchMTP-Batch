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
    static func verify(url: URL,
                       format: PackageFormat,
                       keysetURL: URL,
                       titleKeysURL: URL? = nil,
                       hactoolURL: URL) -> DeepResult {
        if format.isCompressed {
            return DeepResult(state: .unavailable, notes: [
                .init(severity: .warning, title: "压缩包无法直接深度校验",
                      detail: "这是 \(format.displayName)。签名与哈希位于解压后的 NCA 内部；本版不做解包，因此只能说“外层结构正常、签名未验证”。DBI 自己能装 NSZ，装完可能是绿，所以这里不能给绿。")
            ], detail: "NSZ/XCZ 需要解压后校验")
        }

        // XCI verification is header-only unless the cartridge image is walked
        // partition by partition; claiming more than that would be a lie.
        guard format == .nsp else {
            return DeepResult(state: .unavailable, notes: [
                .init(severity: .note, title: "该格式尚未做逐 NCA 验签",
                      detail: "当前引擎只能对 NSP 逐个 NCA 验签名与哈希。\(format.displayName) 只验到容器头，结论等于“未验签”，不等于 DBI 的绿色。")
            ], detail: "格式未支持逐 NCA 验签")
        }

        var arguments = ["-i", "-y", "--disablekeywarns", "--suppresskeys", "-k", keysetURL.path]
        if let titleKeysURL {
            arguments += ["--titlekeys", titleKeysURL.path]
        }
        arguments += ["-t", "nsp", url.path]

        let output: String
        switch run(hactoolURL, arguments: arguments, timeout: 1800) {
        case .failure(let message):
            return DeepResult(state: .unavailable, notes: [
                .init(severity: .warning, title: "校验引擎未能运行", detail: message)
            ], detail: message)
        case .success(let text):
            output = text
        }

        return interpret(output: output, format: format)
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
        // proof of a bad package. (某样本 retail sample: 3/4 NCAs hash GOOD once the
        // ticket key is derived, which is how this distinction was calibrated.)
        let registeredKeys = Self.markerValue("NSP_KEYSTATE", field: "registered", in: output) ?? 1

        // 2. A hash mismatch that is *not* explained by a missing title key is
        //    corruption: DBI would fail to install it. Red.
        if let first = hashFails.first {
            if registeredKeys == 0 {
                return DeepResult(state: .unavailable, notes: [
                    .init(severity: .warning, title: "未取得标题密钥，哈希无从校验",
                          detail: "引擎没能从包内 ticket 解出标题密钥（个人化票据或缺少 ticket）。哈希不符只是“没解开”，不代表文件损坏。")
                ], detail: "\(first.name) 无法解密", ncas: checks)
            }
            return DeepResult(state: .failed, notes: [
                .init(severity: .blocking, title: "签名保留、内容哈希不符（DBI 会安装失败）",
                      detail: "NCA 头签名是真的，但解出来的内容与清单哈希对不上：典型特征是该 NCA 被替换、重打包不完整或传输损坏。DBI 装到这一层会报错，对应红色。")
            ], detail: "\(first.name) 哈希校验失败", ncas: checks)
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

        // 6. Full pass: every NCA signed by retail, hashes verified where they
        //    could be computed, and nothing failed.
        var notes: [CheckNote] = [
            .init(severity: .note, title: "签名与哈希通过（对应 DBI 绿）",
                  detail: "\(signatureGoods.count) 个 NCA 的零售签名全部成立，\(hashGoods.count) 个 NCA 的内容哈希通过。")
        ]
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
                if let previous = current {
                    var fresh = NCACheck(name: previous.name)
                    let detail = line.replacingOccurrences(of: "NSP_NCA_RETRY:", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    fresh.note = "已按内容实际密钥代重验（\(detail)）"
                    current = fresh
                }
                continue
            }
            if line.hasPrefix("NSP_NCA_END:") {
                if let finished = current { results.append(finished) }
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

            if lower.contains("hash (good)") {
                if check.hash == .unknown { check.hash = .good }
            } else if lower.contains("hash (fail)") || lower.contains("is corrupted") || lower.contains("hash mismatch") {
                check.hash = .fail
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
            }
            current = check
        }
        if let finished = current { results.append(finished) }
        return results
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

    static func run(_ executable: URL, arguments: [String], timeout: TimeInterval) -> RunOutcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // A private scratch directory keeps output out of the user's home and
        // out of any log the app writes.
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hactool-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: outputURL) }

        guard let handle = try? FileHandle(forWritingTo: outputURL) else {
            return .failure("无法创建校验输出文件")
        }
        process.standardOutput = handle
        process.standardError = handle

        do {
            try process.run()
        } catch {
            try? handle.close()
            return .failure(error.localizedDescription)
        }

        let timeoutWork = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

        process.waitUntilExit()
        timeoutWork.cancel()
        try? handle.close()

        let data = (try? Data(contentsOf: outputURL)) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? ""
        if process.terminationStatus != 0, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure("校验引擎异常退出（\(process.terminationStatus)）")
        }
        return .success(text)
    }
}

struct DeepResult {
    var state: DeepCheckState
    var notes: [CheckNote]
    var detail: String
    var ncas: [DeepVerifier.NCACheck] = []
}
