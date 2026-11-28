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
    let onCancel: () -> Void
    @State private var acknowledgesRisk = false

    /// Unverified / non-official items need one explicit click: DBI may still
    /// turn them yellow (or refuse), and we must not let that read as a pass.
    private var needsRiskAcknowledgement: Bool {
        plan.counts.unverified > 0 || plan.counts.caution > 0
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
                                existingPill("主机已有", .purple)
                            } else if let pill = updatePill(package) {
                                pill
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
                    noteRow("exclamationmark.triangle.fill", "有 \(plan.counts.caution) 个注意项目：签名不是零售链，或容器结构需注意；DBI 装完可能显示黄色，非官方签名需主机已有 sigpatch。")
                }
                if let shortfall = model.spaceShortfall {
                    noteRow("externaldrive.badge.exclamationmark", "目标空间可能不足：还差约 \(ByteCountFormatter.string(fromByteCount: shortfall, countStyle: .file))。")
                }
                if needsRiskAcknowledgement {
                    Toggle(isOn: $acknowledgesRisk) {
                        Text("我已知晓：含未验签/非官方内容，DBI 可能显示黄色或拒绝安装")
                            .font(.system(size: 10))
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)

            Divider()

            HStack(alignment: .center) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("安装过程中请保持 USB 连接、不要锁屏休眠，中断可能导致安装不完整。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("取消") { onCancel() }
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

    private func existingPill(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    /// Update-only comparison pill. Base/DLC duplicates use `existingPill` via
    /// `isAlreadyOnConsole`; `.notInstalled` returns no pill.
    private func updatePill(_ package: InstallPackage) -> AnyView? {
        switch model.updateMatch(package) {
        case .sameVersion: return AnyView(existingPill("已有同版本", .purple))
        case .upgradable: return AnyView(existingPill("可升级", .blue))
        case .outdated: return AnyView(existingPill("主机已是新版", .secondary))
        case .notInstalled: return nil
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
                info: "applet（相册/hbmenu）模式下压缩包需在主机解压，可能被 DBI 拒绝；建议用 title 模式启动 DBI 后发送。"
            ) else { return }
        }

        let duplicates = plan.packages.filter { model.needsOverwriteConfirm($0) }
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
            alert.messageText = "有 \(names.count) 个项目已安装在主机上，是否确认覆盖安装？"
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
