// SwitchMTP Batch — a macOS MTP client for Nintendo Switch running DBI.
// Copyright (C) 2025 fratei
//
// This program is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License version 2 as published by
// the Free Software Foundation.

// The last gate before bytes move. Everything here is a frozen snapshot from
// `makePlan()`, so the numbers cannot change while the sheet is open.

import SwiftUI

struct BatchConfirmSheet: View {
    let plan: InstallPlan
    @ObservedObject var model: BatchInstallModel
    @ObservedObject var manager: MTPManager
    let onFinished: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledgesRisk = false

    /// Unverified / non-official items need one explicit click: DBI may still
    /// turn them yellow (or refuse), and we must not let that read as a pass.
    private var needsRiskAcknowledgement: Bool {
        plan.counts.unverified > 0 || plan.counts.caution > 0
    }

    /// Packages that never ran the deep pass get their own acknowledgement:
    /// their signature/hash has not been checked at all, so the user must
    /// consciously proceed without that evidence.
    private var needsUncheckedAcknowledgement: Bool {
        plan.uncheckedDeepCount > 0
    }

    /// Compressed titles (NSZ/XCZ) need a separate acknowledgement: in album /
    /// hbmenu (applet) mode DBI decompresses them on the console and such titles
    /// can be refused. This is an environment risk keyed by format, independent
    /// of the signature axis and of package size.
    private var needsModeAcknowledgement: Bool {
        plan.advisoryCount > 0
    }

    private var targetName: String {
        plan.targetKind == .nandInstall ? "NAND" : "SD 卡"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("确认安装计划").font(.system(size: 16, weight: .semibold))
                    Text("以下项目会按顺序逐个发送到 DBI，同一时刻只安装一个。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(18)

            Divider()

            HStack(spacing: 18) {
                metric("项目", "\(plan.packages.count)")
                metric("总大小", plan.totalSizeText)
                metric("目标", targetName)
                metric("已验证原版", "\(plan.counts.passed)")
                metric("未验签", "\(plan.counts.unverified)")
                metric("非官方", "\(plan.counts.caution)")
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(plan.packages) { package in
                        HStack(spacing: 8) {
                            Image(systemName: package.resolvedVerdict.shortSymbol)
                                .foregroundStyle(color(package.resolvedVerdict))
                                .font(.system(size: 11))
                            if package.needsTitleModeAdvisory {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .font(.system(size: 10))
                                    .help("NSZ/XCZ 压缩包：applet（相册/hbmenu）模式下需在主机端解压，可能被 DBI 拒绝；建议 title 模式启动 DBI。")
                            }
                            Text(package.contentType.displayName)
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.secondary.opacity(0.12)))
                            Text(model.displayTitle(for: package))
                                .font(.system(size: 11))
                                .lineLimit(1)
                            if model.isAlreadyOnConsole(package) {
                                Text("主机已有")
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.purple.opacity(0.15)))
                                    .foregroundStyle(.purple)
                            }
                            Spacer()
                            Text(package.sizeText)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            .frame(minHeight: 180, maxHeight: 320)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                if plan.counts.caution > 0 {
                    noteRow("exclamationmark.triangle.fill", "有 \(plan.counts.caution) 个注意项目：签名不是零售链，或容器结构需注意。DBI 装完可能显示黄色，需要主机已有 sigpatch。")
                }
                if plan.counts.unverified > 0 {
                    noteRow("questionmark.circle.fill", "有 \(plan.counts.unverified) 个待确认项目：本机没验成签名/哈希（密钥不足、个人化票据或未解包），证据不足、不代表文件损坏，不能当作原版绿；最终以 DBI 实机结果为准。")
                }
                if needsUncheckedAcknowledgement {
                    noteRow("shield.slash", "有 \(plan.uncheckedDeepCount) 个项目尚未做深度检查：签名链与内容哈希都没验过。可先关闭本页点「深度检查」补验；直接发送则按未验签处理，DBI 可能显示黄色。")
                }
                if needsModeAcknowledgement {
                    noteRow("arrow.up.forward.app", "有 \(plan.advisoryCount) 个压缩包（NSZ/XCZ）：在相册 / hbmenu（applet）模式下需在主机端解压，可能被 DBI 拒绝并提示“需要 title 模式”。建议按住 R 从任意已安装游戏标题启动 DBI（title 模式）后再发送；纯 NSP/XCI 不受此限制。")
                }
                if let shortfall = model.spaceShortfall {
                    noteRow("externaldrive.badge.exclamationmark", "目标空间可能不足：还差约 \(ByteCountFormatter.string(fromByteCount: shortfall, countStyle: .file))。")
                }
                if needsRiskAcknowledgement {
                    Toggle(isOn: $acknowledgesRisk) {
                        Text("我已知晓：勾选项目中有未验签/非官方内容，DBI 可能报黄色或拒绝安装")
                            .font(.system(size: 10))
                    }
                    .toggleStyle(.checkbox)
                }
                noteRow("info.circle.fill", "SwitchMTP Batch 只能确认“文件已发送给 DBI”。最终安装成功与否、DBI 屏幕上显示什么颜色，只能看主机本身；本应用不会代你宣称安装成功。")
                noteRow("exclamationmark.triangle.fill", "安装过程中请保持 USB 连接、不要锁屏休眠。中断可能让主机留下半个游戏。")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)

            Divider()

            HStack {
                if model.lastSubmittedCount == 0 {
                    Text("点击“确认安装”后才会开始传输。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    confirmAndCommit()
                } label: {
                    Label("确认安装 \(plan.packages.count) 项", systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(needsRiskAcknowledgement && !acknowledgesRisk)
            }
            .padding(16)
        }
        .frame(width: 620)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .semibold))
        }
    }

    private func noteRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Sends the plan after the explicit prompts: the applet-mode warning
    /// (unchecked titles were warned before the sheet opened), then titles
    /// already on the console. Cancelling any prompt leaves the sheet open.
    private func confirmAndCommit() {
        if needsModeAcknowledgement {
            guard presentWarning(
                title: "有 \(plan.advisoryCount) 个压缩包（NSZ/XCZ）",
                info: "在相册 / hbmenu（applet）模式下需在主机端解压，可能被 DBI 拒绝并提示“需要 title 模式”。建议按住 R 从任意已安装游戏标题启动 DBI（title 模式）后再发送；纯 NSP/XCI 不受此限制。"
            ) else { return }
        }

        let duplicates = plan.packages.filter { model.isAlreadyOnConsole($0) }
        guard !duplicates.isEmpty else {
            model.commit(plan: plan)
            onFinished()
            return
        }

        let names = duplicates.map { model.displayTitle(for: $0) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if names.count == 1 {
            alert.messageText = "「\(names[0])」已安装在主机上，是否确认覆盖安装？"
        } else {
            alert.messageText = "有 \(names.count) 个游戏已安装在主机上，是否确认覆盖安装？"
        }
        alert.informativeText = "已在主机上：\n" + names.joined(separator: "\n")
        alert.addButton(withTitle: "覆盖安装")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.commit(plan: plan)
        onFinished()
    }

    /// One modal warning. Returns true only when the user confirms proceeding.
    private func presentWarning(title: String, info: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: "仍然安装")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func color(_ verdict: PackageVerdict) -> Color {
        switch verdict {
        case .passed: return .green
        case .unverified: return .teal
        case .caution: return .orange
        case .blocked: return .red
        case .pending: return .secondary
        }
    }
}
