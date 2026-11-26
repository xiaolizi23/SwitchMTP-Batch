// SwitchMTP Batch — a macOS MTP client for Nintendo Switch running DBI.
// Copyright (C) 2025 fratei
//
// This program is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License version 2 as published by
// the Free Software Foundation.

// The batch workspace UI: import, review, confirm, send.
//
// Deliberately one window with three columns worth of work in it, because the
// whole point is that nothing is transmitted until the user has seen what the
// folder actually contains. The visual language borrows SwitchDownloader's
// queue idea (grouped tree, per-item checkboxes, a single batch confirm) but
// none of its code: that project ships no licence file, and its classification
// is filename guessing, which this workspace only uses as a last resort.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct BatchInstallSheet: View {
    @ObservedObject var manager: MTPManager
    @StateObject private var model: BatchInstallModel
    @Environment(\.dismiss) private var dismiss

    /// Set when the workspace is hosted in its own window. `dismiss` only
    /// unwinds a SwiftUI presentation, so the window needs its own way out.
    var onClose: (() -> Void)?

    @State private var pendingPlan: InstallPlan?
    @State private var selectedPackageID: UUID?
    /// A whole game can be selected without expanding it: the detail pane then
    /// shows its cover, counts and members instead of an empty placeholder.
    @State private var selectedGroupID: String?
    @State private var expandedGroups: Set<String> = []
    @State private var showKeyPanel = false
    @State private var isDropTargeted = false

    init(manager: MTPManager, onClose: (() -> Void)? = nil) {
        self.manager = manager
        self.onClose = onClose
        _model = StateObject(wrappedValue: BatchInstallModel(manager: manager))
    }

    private func closeWorkspace() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                leftColumn
                    .frame(minWidth: 520)
                detailColumn
                    .frame(minWidth: 300, idealWidth: 330, maxWidth: 420)
            }
            Divider()
            footer
        }
        // The floor comes from WindowMetrics so it cannot drift away from the
        // main window's floor again. The three columns keep their own
        // minimums (520 / 300).
        .frame(minWidth: WindowMetrics.workspaceMinFrame.width,
               minHeight: WindowMetrics.workspaceMinFrame.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop(providers:))
        .overlay(dropOverlay)
        .sheet(isPresented: $showKeyPanel) {
            KeySetPanel(model: model) { showKeyPanel = false }
        }
        .sheet(item: Binding(get: { pendingPlan.map(PlanBox.init) },
                             set: { if $0 == nil { pendingPlan = nil } })) { box in
            BatchConfirmSheet(plan: box.plan, model: model, manager: manager) {
                // The send has been handed to DBI, but the run is still going on
                // the console. Closing the workspace here would throw away the
                // only record of what this batch was made of, so it stays open
                // with the sent items marked "已交给 DBI".
                pendingPlan = nil
            }
            // A cancelled confirm leaves the plan untouched by design.
        }
        .onChange(of: model.banner) { _ in }
        .onAppear(perform: loadAutomationFixture)
    }

    /// Automation hook: `SWITCHMTP_BATCH_TEST_FOLDER` pre-loads a folder so an
    /// AX / computer-use test can start from a known fixture without driving an
    /// open panel. Same pattern as SWITCHMTP_DEBUG_LOG / SWITCHMTP_HACTOOL,
    /// and it never touches USB on its own.
    private func loadAutomationFixture() {
        guard model.packages.isEmpty,
              let path = ProcessInfo.processInfo.environment["SWITCHMTP_BATCH_TEST_FOLDER"],
              !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        model.importURLs([url])
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("批量安装")
                    .font(.system(size: 18, weight: .semibold))
                Text("先把整个文件夹拖进来 → 检查 → 勾选 → 一次确认后按顺序发送给 DBI")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()

            keyStatusChip

            if !model.installTargets.isEmpty {
                Picker("", selection: $model.targetKind) {
                    ForEach(model.installTargets) { storage in
                        Text(storage.kind == .nandInstall ? "NAND" : "SD 卡")
                            .tag(storage.kind)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .help("DBI 的安装目标存储")
            } else if let holder = manager.deviceLeaseHolder {
                Label("设备被另一个实例占用", systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .help("另一个 SwitchMTP Batch 实例（\(holder)）正在使用 Switch。关掉它之后这里会自动接管。")
            } else {
                Label("未连接主机", systemImage: "cable.connector.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            Button {
                model.runDeepCheck()
            } label: {
                Label(model.isDeepChecking
                      ? "深度检查 \(model.deepCheckDone)/\(model.deepCheckTotal)"
                      : "深度检查",
                      systemImage: "checkmark.shield")
            }
            .disabled(model.isDeepChecking || model.isScanning || model.packages.isEmpty)

            Button("关闭") { closeWorkspace() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        // The window draws no title of its own (see BatchWorkspaceWindow); the
        // hosting view already keeps clear of the traffic lights, so this is a
        // normal header inset, not an extra title-bar offset.
        .padding(.vertical, 12)
    }

    private var keyStatusChip: some View {
        Button {
            showKeyPanel = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.keySetLoaded ? "key.fill" : "key")
                Text(model.keySetLoaded ? "prod.keys 已载入" : "未设置密钥")
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(model.keySetLoaded ? Color.green.opacity(0.16) : Color.secondary.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .help("结构检查不需要密钥；签名与哈希验证需要你自己的 prod.keys。")
    }

    // MARK: - Left column

    private var leftColumn: some View {
        VStack(spacing: 0) {
            importBar
            if let banner = model.banner {
                bannerView(banner)
            }
            if model.packages.isEmpty {
                emptyState
            } else {
                planToolbar
                Divider()
                planList
            }
        }
    }

    private var importBar: some View {
        HStack(spacing: 8) {
            Button {
                chooseFolders()
            } label: {
                Label("选择文件夹", systemImage: "folder.badge.plus")
            }
            Button {
                chooseFiles()
            } label: {
                Label("选择文件", systemImage: "doc.badge.plus")
            }
            if model.isScanning {
                ProgressView().controlSize(.small)
                Text(model.scanHeadline)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("取消") { model.cancelScan() }
                    .controlSize(.small)
            } else if !model.roots.isEmpty {
                if model.catalogStatus != nil {
                    ProgressView().controlSize(.small)
                }
                Text(model.catalogStatus
                     ?? (model.scanHeadline.isEmpty
                         ? "\(model.packages.count) 个包 · \(model.totalSizeText)"
                         : model.scanHeadline))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    model.rescanAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .controlSize(.small)
                .help("重新扫描已加入的文件夹")
            }
            Spacer()
            if !model.packages.isEmpty {
                if model.isFetchingIcons {
                    ProgressView().controlSize(.small)
                }
                // Only takes toolbar space while something is still missing,
                // so a fully covered library keeps the full size summary.
                if model.hasMissingCovers {
                    Button {
                        model.refreshIcons()
                    } label: {
                        Image(systemName: "photo.badge.arrow.down")
                    }
                    .controlSize(.small)
                    .help("重新获取游戏封面（已缓存的直接从本机读取）")
                }
            }
            if !model.packages.isEmpty {
                Button(role: .destructive) {
                    model.clearAll()
                    selectedPackageID = nil
                } label: {
                    Label("清空", systemImage: "trash")
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func bannerView(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: model.bannerIsError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(model.bannerIsError ? .orange : .accentColor)
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                model.banner = nil
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.06))
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: isDropTargeted ? "arrow.down.circle.fill" : "square.stack.3d.down.forward")
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(isDropTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            Text("把游戏总目录拖到这里")
                .font(.system(size: 16, weight: .semibold))
            Text("会递归分析子文件夹，自动分出本体 / 更新 / DLC，\n列成可勾选的清单。扫描阶段不会传输任何文件。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                ForEach(["nsp", "nsz", "xci", "xcz"], id: \.self) { ext in
                    Text(ext.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .center) {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
                .foregroundStyle(isDropTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.25)))
                .padding(24)
        }
    }

    private var planToolbar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $model.filter) {
                ForEach(PlanFilter.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 300)

            Menu {
                ForEach(PlanSort.allCases, id: \.self) { sort in
                    Button(sort.displayName) { model.sort = sort }
                }
            } label: {
                Label("排序：\(model.sort.displayName)", systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            Button("全选") { model.setAllVisible(true) }
                .controlSize(.small)
            Button("全不选") { model.setAllVisible(false) }
                .controlSize(.small)
            Button("仅可选") { model.selectAllPassed() }
                .controlSize(.small)
                .help("只勾选检查通过或仅“注意”的项目")

            Button {
                if expandedGroups.isEmpty {
                    expandedGroups = Set(model.visibleGroups.map(\.id))
                } else {
                    expandedGroups.removeAll()
                }
            } label: {
                Image(systemName: expandedGroups.isEmpty ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
            }
            .buttonStyle(.borderless)
            .help("展开/收起全部")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// The plan list is a plain scrolling stack, not a `List`.
    ///
    /// `List` / `DisclosureGroup` are table controls: their rows surface as
    /// `AXRow` / `AXCell` in the accessibility tree, and the computer-use
    /// enumerator merges such a row into one selectable element, dropping the
    /// checkbox nested in it. `ScrollView + VStack` keeps everything SwiftUI
    /// does for layout (intrinsic row heights, dividers, dynamic type, dark
    /// mode) while the accessibility tree only holds ordinary containers and
    /// real buttons, so each checkbox stays individually addressable.
    private var planList: some View {
        ScrollView(.vertical) {
            planRows
                .padding(.top, 10)
                .padding(.bottom, 4)
                .padding(.trailing, 16)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .safeAreaInset(edge: .top, spacing: 0) {
            searchBar
        }
        // SwiftUI exposes no accessibility-role modifier (checked against the
        // SDK: no AccessibilityRole symbol), and its ScrollView is not an
        // NSScrollView, so an AXList role cannot be attached from inside
        // without an AppKit host — which would risk the enumeration this
        // layout exists for. What is possible is done here: a named container
        // plus a summary, so VoiceOver announces the region and its size.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("批量安装清单")
        .accessibilityHint("\(model.visibleGroups.count) 个游戏，共 \(model.packages.count) 个安装包")
        .accessibilityIdentifier("plan-list")
    }

    /// Non-lazy up to this many rows. Below it every row stays in the view (and
    /// accessibility) tree, so an automation client can address a package
    /// without scrolling to it first. Past it that is no longer affordable and
    /// the stack goes lazy: offscreen rows then only exist once they are
    /// scrolled into view.
    private static let nonLazyRowLimit = 200

    private var planRowCount: Int {
        model.visibleGroups.reduce(0) { count, group in
            count + 1 + (expandedGroups.contains(group.id) ? group.packages.count : 0)
        }
    }

    @ViewBuilder
    private var planRows: some View {
        if planRowCount <= Self.nonLazyRowLimit {
            VStack(alignment: .leading, spacing: 0) { planRowContent }
        } else {
            LazyVStack(alignment: .leading, spacing: 0) { planRowContent }
        }
    }

    @ViewBuilder
    private var planRowContent: some View {
        ForEach(Array(model.visibleGroups.enumerated()), id: \.element.id) { index, group in
            groupRow(group)
                .overlay(alignment: .bottom) {
                    if !(index == model.visibleGroups.count - 1 && !expandedGroups.contains(group.id)) {
                        rowSeparator(leading: 92)
                    }
                }
            if expandedGroups.contains(group.id) {
                ForEach(Array(group.packages.enumerated()), id: \.element.id) { packageIndex, package in
                    // `List` nested disclosure content 17 pt deeper than the
                    // group row (51.5 vs 34.5 pt); 46 pt lands the checkbox
                    // on the same pixel.
                    packageRow(package)
                        .padding(.leading, 46)
                        .padding(.trailing, 8)
                        .padding(.vertical, 2)
                        .overlay(alignment: .bottom) {
                            if !(index == model.visibleGroups.count - 1 && packageIndex == group.packages.count - 1) {
                                rowSeparator(leading: 79)
                            }
                        }
                }
            }
        }
    }

    /// Hairline between plan rows, drawn as an overlay so it costs no height —
    /// the same way `List` paints its separators. Numbers traced from the
    /// 1.7.12 release build: group rows start the line at the text column
    /// (92 pt), member rows at the type capsule (79 pt), both stop at 541 pt.
    private func rowSeparator(leading: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .padding(.leading, leading)
            .padding(.trailing, 0.5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索名称、Title ID 或路径", text: $model.searchText)
                .textFieldStyle(.plain)
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(.bar)
    }

    /// Clicking a group row does both things at once: it expands (or collapses)
    /// the group and selects the game for the detail pane (cover, name, counts,
    /// member list). Expanding on the row click is what a Finder outline row
    /// does, so the first click no longer feels like it only changed the pane.
    private func groupRow(_ group: InstallPackageGroup) -> some View {
        let expanded = expandedGroups.contains(group.id)
        return HStack(spacing: 8.5) {
            Button {
                if expanded {
                    expandedGroups.remove(group.id)
                } else {
                    expandedGroups.insert(group.id)
                }
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 14)
                    // 1.5 device px higher, which is where `List`'s own
                    // disclosure triangle sits (measured on 1.7.12).
                    .offset(y: -0.75)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "收起 \(group.name)" : "展开 \(group.name)")
            .accessibilityIdentifier("group-expand-\(group.id)")

            groupHeader(group)
        }
        // 12.5 + 8.5 pt gap puts the chevron and checkbox on the 1.7.12
        // coordinates (16.5 / 34.5 pt); `List`'s row inset did the same.
        .padding(.leading, 12.5)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if expanded {
                expandedGroups.remove(group.id)
            } else {
                expandedGroups.insert(group.id)
            }
            selectedGroupID = group.id
            selectedPackageID = nil
        }
    }

    private func groupHeader(_ group: InstallPackageGroup) -> some View {
        HStack(spacing: 8) {
            Button {
                model.setGroupSelection(group, selected: group.eligibleSelectedCount == 0)
            } label: {
                Image(systemName: groupIcon(group))
                    .font(.system(size: 13))
                    .foregroundStyle(verdictColor(group.verdict))
            }
            .buttonStyle(.plain)
            .disabled(group.eligibleCount == 0)
            .help(group.eligibleCount == 0
                ? "组内项目均未通过检查，不可勾选"
                : "勾选/取消整个组（未通过项目不参与勾选）")
            .accessibilityLabel(group.eligibleSelectedCount == 0 ? "勾选整组 \(group.name)" : "取消勾选整组 \(group.name)")
            .accessibilityValue("\(group.selectedCount)/\(group.packages.count)")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("group-checkbox-\(group.id)")

            groupThumbnail(group)

            Text(group.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)

            if let base = group.baseTitleID {
                Text(base)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Text("\(group.packages.count) 项")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text("·")
                .foregroundStyle(.tertiary)
            Text(group.sizeText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Spacer()

            if group.submittedCount > 0 {
                badge("已交给 DBI \(group.submittedCount)", color: .blue)
            }
            if group.hasBlocked {
                badge("含阻止项", color: .red)
            }
            if group.hasCaution {
                badge("需注意", color: .orange)
            }
            Text("\(group.selectedCount)/\(group.packages.count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    /// 28 pt square, rounded like a HOME menu tile. It always draws the same
    /// footprint: the fetched cover when the catalogue had one, a neutral
    /// placeholder otherwise, so rows keep a steady height while icons stream
    /// in.
    private func groupThumbnail(_ group: InstallPackageGroup) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary)
            if let titleID = group.baseTitleID, let icon = model.titleIcons[titleID] {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        // Without this an oversize source image would ignore the frame; the
        // clip keeps hostile or unusual aspect ratios inside the tile.
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
    }

    private func groupIcon(_ group: InstallPackageGroup) -> String {
        // 三态按全组成员判断：只要还有未勾选的成员（含不可勾选的阻止项），
        // 就保持横杠，不出现「全选对勾」。勾选动作本身只作用于可勾成员。
        if group.selectedCount == 0 { return "square" }
        if group.selectedCount == group.packages.count { return "checkmark.square.fill" }
        return "minus.square.fill"
    }

    private func packageRow(_ package: InstallPackage) -> some View {
        let isSelectedRow = selectedPackageID == package.id
        return HStack(spacing: 8) {
            Button {
                model.togglePackage(package.id)
            } label: {
                Image(systemName: checkboxIcon(package))
                    .font(.system(size: 13))
                    .foregroundStyle(package.isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .disabled(package.resolvedVerdict == .blocked || package.isSubmitted)
            .help(packageHelp(package))
            .accessibilityLabel(package.isSelected ? "取消勾选 \(package.displayName)" : "勾选 \(package.displayName)")
            .accessibilityValue(package.isSelected ? "已选择" : "未选择")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("package-checkbox-\(package.id.uuidString)")

            Text(package.contentType.displayName)
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(typeColor(package.contentType).opacity(0.16)))
                .foregroundStyle(typeColor(package.contentType))

            VStack(alignment: .leading, spacing: 1) {
                Text(package.displayName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(package.isSubmitted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                HStack(spacing: 6) {
                    Text(package.format.displayName)
                    if let version = package.version {
                        Text("v\(version)")
                    }
                    if let titleID = package.titleID {
                        Text(titleID).font(.system(size: 9, design: .monospaced))
                    }
                    Text(package.url.deletingLastPathComponent().lastPathComponent)
                        .lineLimit(1)
                }
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                if package.deepState != .notRun {
                    rowProgressBar(package)
                }
            }
            // Expand to fill the leftover width instead of hugging the longest
            // text line, so the progress bar has the same length on every row.
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 6)

            let main = mainRowIcon(package)
            Image(systemName: main.name)
                .font(.system(size: 12))
                .foregroundStyle(main.color)
                // Fixed slots keep the icon column vertically aligned across
                // rows whether or not a second deep-check icon is present.
                .frame(width: 18, height: 18)
                .help(main.help)

            if package.deepState != .notRun && package.deepState != .running {
                Image(systemName: deepIcon(package.deepState))
                    .font(.system(size: 11))
                    .foregroundStyle(deepColor(package.deepState))
                    .frame(width: 18, height: 18)
                    .help("深度检查：\(package.deepState.displayName)")
            } else {
                Color.clear.frame(width: 18, height: 18)
            }

            Text(package.sizeText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        // 1.7.12 tints the chosen package row with 10% accent; the group row
        // stays untinted because `List` never had a group selection there.
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelectedRow ? Color.accentColor.opacity(0.10) : Color.clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .onTapGesture {
            selectedPackageID = package.id
            selectedGroupID = nil
        }
    }

    private func packageHelp(_ package: InstallPackage) -> String {        if package.isSubmitted { return "已交给 DBI，本次不再重复发送" }
        switch package.resolvedVerdict {
        case .blocked: return "检查未通过（结构或内容损坏），默认不允许安装"
        case .unverified: return "本机未能完成签名/哈希校验：证据不足，不代表文件已损坏；勾选后安装前会要求确认，最终以 DBI 实机结果为准"
        case .caution: return "签名非官方，或容器结构需注意；通常需要 sigpatch，勾选后安装前会要求确认"
        default: return "勾选以加入安装计划"
        }
    }

    private func ncaIcon(_ nca: DeepVerifier.NCACheck) -> String {
        if nca.isTitleKeyMissing { return "questionmark.circle" }
        switch (nca.signature, nca.hash) {
        case (.good, .good): return "checkmark.seal.fill"
        case (.good, .fail): return "xmark.seal.fill"
        case (.fail, _): return "signature"
        default: return "circle.dotted"
        }
    }

    private func ncaColor(_ nca: DeepVerifier.NCACheck) -> Color {
        if nca.isTitleKeyMissing { return .teal }
        switch (nca.signature, nca.hash) {
        case (.good, .good): return .green
        case (.good, .fail): return .red
        case (.fail, _): return .orange
        default: return .secondary
        }
    }

    private func checkboxIcon(_ package: InstallPackage) -> String {
        if package.resolvedVerdict == .blocked { return "xmark.square" }
        return package.isSelected ? "checkmark.square.fill" : "square"
    }

    // MARK: - Detail

    private var detailColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let package = model.packages.first(where: { $0.id == selectedPackageID }) {
                detail(for: package)
            } else if let group = model.groups.first(where: { $0.id == selectedGroupID }) {
                groupDetail(for: group)
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 24, weight: .thin))
                        .foregroundStyle(.quaternary)
                    Text("点选任一游戏或安装包查看详情")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.35))
    }

    /// Collapsed-game overview: cover, name, counts and what is inside, so a
    /// click on a group row answers "what is this, and what would I install"
    /// without expanding it first.
    private func groupDetail(for group: InstallPackageGroup) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    groupCover(group, side: 88)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            badge("\(group.packages.count) 项", color: .accentColor)
                            Text(group.verdict.displayName)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(verdictColor(group.verdict))
                            if group.hasBlocked { badge("含阻止项", color: .red) }
                            if group.hasCaution { badge("需注意", color: .orange) }
                        }
                        Text(group.name)
                            .font(.system(size: 15, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        if let base = group.baseTitleID {
                            Text("Base Title ID \(base)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Text("已勾选 \(group.selectedCount)/\(group.packages.count) · 合计 \(group.sizeText)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        if group.submittedCount > 0 {
                            Text("其中 \(group.submittedCount) 项已交给 DBI")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("包含的安装包")
                        .font(.system(size: 11, weight: .semibold))
                    ForEach(group.packages) { package in
                        HStack(spacing: 6) {
                            Text(package.contentType.displayName)
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(typeColor(package.contentType).opacity(0.16)))
                                .foregroundStyle(typeColor(package.contentType))
                            Text(package.displayName)
                                .font(.system(size: 10))
                                .lineLimit(1)
                            if let version = package.version {
                                Text("v\(version)")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Circle()
                                .fill(verdictColor(package.resolvedVerdict))
                                .frame(width: 6, height: 6)
                            Text(package.sizeText)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .frame(width: 62, alignment: .trailing)
                        }
                    }
                }

            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Detail-pane cover, same artwork source as the row thumbnail.
    private func groupCover(_ group: InstallPackageGroup, side: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary)
            if let titleID = group.baseTitleID, let icon = model.titleIcons[titleID] {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: side * 0.32))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }

    private func detail(for package: InstallPackage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(package.contentType.displayName)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(typeColor(package.contentType).opacity(0.16)))
                            .foregroundStyle(typeColor(package.contentType))
                        Text(package.resolvedVerdict.displayName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(verdictColor(package.resolvedVerdict))
                    }
                    Text(package.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(package.url.path)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                detailGrid(package)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("检查结果")
                        .font(.system(size: 11, weight: .semibold))
                    if package.notes.isEmpty {
                        Text("结构检查未发现问题。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(package.notes) { note in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: noteIcon(note.severity))
                                    .font(.system(size: 10))
                                    .foregroundStyle(noteColor(note.severity))
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(note.title).font(.system(size: 11, weight: .medium))
                                    if !note.detail.isEmpty {
                                        Text(note.detail)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }
                }

                if !package.deepNCAs.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 5) {
                        Text("逐 NCA 校验（签名 / 内容哈希）")
                            .font(.system(size: 11, weight: .semibold))
                        ForEach(package.deepNCAs) { nca in
                            HStack(spacing: 6) {
                                Image(systemName: ncaIcon(nca))
                                    .font(.system(size: 10))
                                    .foregroundStyle(ncaColor(nca))
                                Text(nca.name)
                                    .font(.system(size: 9, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 4)
                                Text(nca.signatureText)
                                    .font(.system(size: 9))
                                    .foregroundStyle(nca.signature == .good ? .green : (nca.signature == .fail ? .orange : .secondary))
                                Text(nca.hashText)
                                    .font(.system(size: 9))
                                    .foregroundStyle(nca.hash == .good ? .green : (nca.hash == .fail ? .red : .secondary))
                            }
                            if let note = nca.note, !note.isEmpty {
                                Text(note)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                Divider()

                HStack(spacing: 10) {
                    if package.format == .nsz {
                        Button {
                            chooseUnpackDestination(for: package)
                        } label: {
                            Label("解包为 NSP…", systemImage: "archivebox")
                        }
                        .controlSize(.small)
                        .help("把 NSZ 的 NCZ 解压并按 section 重加密，写出可直接安装的 NSP；完成后会对照包内 CNMT 哈希自检。")
                    }
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([package.url])
                    } label: {
                        Label("在 Finder 中显示", systemImage: "folder")
                    }
                    .controlSize(.small)
                    Button(role: .destructive) {
                        model.removePackages(in: package.groupKey)
                        selectedPackageID = nil
                    } label: {
                        Label("移除此组", systemImage: "trash")
                    }
                    .controlSize(.small)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Saves the unpacked NSP wherever the user wants it. The panel runs
    /// app-modal rather than as a SwiftUI sheet so it works from a window that
    /// is itself hosted outside a document scene.
    private func chooseUnpackDestination(for package: InstallPackage) {
        let panel = NSSavePanel()
        panel.title = "解包 NSZ 为 NSP"
        panel.message = "写出的是可直接安装的 NSP（解压后通常比 NSZ 大 10–30%）。完成后会对照包内 CNMT 逐个 NCA 校验 SHA-256。"
        panel.nameFieldStringValue = package.url.deletingPathExtension().lastPathComponent + ".nsp"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.unpack(package, to: url)
        }
    }

    private func detailGrid(_ package: InstallPackage) -> some View {
        VStack(spacing: 6) {
            detailRow("格式", package.format.displayName)
            detailRow("大小", package.sizeText)
            detailRow("Title ID", package.titleID ?? "未识别")
            detailRow("基础 ID", package.baseTitleID ?? "—")
            detailRow("版本", package.version.map { "v\($0)" } ?? "未识别")
            detailRow("NCA 数量", package.report.map { "\($0.ncaCount)" } ?? "—")
            detailRow("TICKET", (package.report?.hasTicket ?? false) ? "有" : "无")
            detailRow("CNMT", (package.report?.hasCnmt ?? false) ? "有" : "无")
            detailRow("深度检查", deepCheckText(package))
        }
        .font(.system(size: 10))
    }

    private func detailRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key).foregroundStyle(.secondary).frame(width: 68, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            summaryChips
            Spacer()
            if model.blockedSelectedCount > 0 {
                Label("已勾选 \(model.blockedSelectedCount) 个未通过项目", systemImage: "exclamationmark.octagon.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }
            if model.submittedCount > 0 {
                Button("清除已发送标记") { model.clearSubmittedMarks() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                    .help("把这些项目重新视为待发送，方便重装或重跑同一批")
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text("已选 \(model.selectedCount) / \(model.packages.count) 项")
                    .font(.system(size: 11, weight: .medium))
                HStack(spacing: 6) {
                    Text(model.selectedSizeText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if model.submittedCount > 0 {
                        Text("· 已交给 DBI \(model.submittedCount)")
                            .font(.system(size: 10))
                            .foregroundStyle(.blue)
                    }
                }
            }
            Button {
                // Deep-check anything still unverified before the sheet opens,
                // so the colours in the plan are evidence, not guesswork.
                model.preparePlan { plan in
                    if let plan { pendingPlan = plan }
                }
            } label: {
                Label(model.isDeepChecking ? "校验中…" : "开始安装", systemImage: "arrow.up.circle.fill")
                    .frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canInstall || model.isDeepChecking)
            .help(model.isDeviceReady ? "" : "先连接 Switch 并在 DBI 里运行 MTP responder")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var summaryChips: some View {
        HStack(spacing: 10) {
            chip(count: model.passedCount, label: "已验证原版", color: .green)
            chip(count: model.unverifiedCount, label: "未验签", color: .teal)
            chip(count: model.cautionCount, label: "非官方", color: .orange)
            chip(count: model.blockedCount, label: "阻止", color: .red)
        }
    }

    private func chip(count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(count) \(label)").font(.system(size: 10))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.10)))
    }

    // MARK: - Drop overlay

    private var dropOverlay: some View {
        Group {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08))
                    .padding(6)
                    .allowsHitTesting(false)
                    .overlay(
                        Text("松开即加入扫描（不会立即安装）")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(10)
                            .background(.regularMaterial, in: Capsule())
                            .allowsHitTesting(false)
                    )
            }
        }
    }

    // MARK: - Pickers and drops

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "加入扫描"
        panel.message = "选择存放游戏、更新与 DLC 的总目录。只会扫描，不会立即安装。"
        if panel.runModal() == .OK { model.importURLs(panel.urls) }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = PackageFormat.allCases.compactMap { UTType(filenameExtension: $0.rawValue) }
        panel.prompt = "加入扫描"
        if panel.runModal() == .OK { model.importURLs(panel.urls) }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var url: URL?
                if let data = item as? Data, let string = String(data: data, encoding: .utf8) {
                    url = URL(string: string)
                } else if let itemURL = item as? URL {
                    url = itemURL
                }
                if let url {
                    lock.lock(); urls.append(url); lock.unlock()
                }
            }
        }
        group.notify(queue: .main) {
            model.importURLs(urls)
        }
        return true
    }

    // MARK: - Small style helpers

    private func verdictColor(_ verdict: PackageVerdict) -> Color {
        switch verdict {
        case .passed: return .green
        case .unverified: return .teal
        case .caution: return .orange
        case .blocked: return .red
        case .pending: return .secondary
        }
    }

    private func typeColor(_ type: PackageContentType) -> Color {
        switch type {
        case .base: return .accentColor
        case .update: return .blue
        case .dlc: return .purple
        case .unknown: return .secondary
        }
    }

    /// Thin under-row track. While the pass runs it fills with the accent
    /// colour at the live fraction reported by the engine; once finished the
    /// track stays full and takes the verdict's colour (green for a full pass).
    private func rowProgressBar(_ package: InstallPackage) -> some View {
        let running = package.deepState == .running
        let fraction = running ? min(max(package.deepProgress, 0), 1) : 1
        let color = running ? Color.accentColor : deepColor(package.deepState)
        return ProgressView(value: fraction)
            .progressViewStyle(.linear)
            .tint(color)
            .frame(height: 3)
            .padding(.top, 2)
    }

    private func deepCheckText(_ package: InstallPackage) -> String {
        guard package.deepState == .running else { return package.deepState.displayName }
        let percent = Int((package.deepProgress * 100).rounded())
        let phase = package.deepPhase ?? "检查中"
        return "\(package.deepState.displayName) · \(phase) \(percent)%"
    }

    /// Primary row glyph. While the deep pass runs, the "pending" verdict
    /// glyph would only duplicate the hourglass, so the hourglass takes the
    /// main slot and the second slot stays an empty placeholder.
    private func mainRowIcon(_ package: InstallPackage) -> (name: String, color: Color, help: String) {
        if package.deepState == .running {
            return ("hourglass", .accentColor, "正在深度检查")
        }
        return (package.resolvedVerdict.shortSymbol,
                verdictColor(package.resolvedVerdict),
                package.resolvedVerdict.displayName)
    }

    private func deepIcon(_ state: DeepCheckState) -> String {
        switch state {
        case .notRun: return "circle.dotted"
        case .running: return "hourglass"
        case .verified: return "checkmark.seal.fill"
        case .signatureOnly: return "checkmark.seal"
        case .signatureInvalid: return "signature"
        case .failed: return "xmark.seal.fill"
        case .unavailable: return "questionmark.circle"
        }
    }

    private func deepColor(_ state: DeepCheckState) -> Color {
        switch state {
        case .notRun: return .secondary
        case .running: return .accentColor
        case .verified: return .green
        case .signatureOnly: return .teal
        case .signatureInvalid: return .orange
        case .failed: return .red
        case .unavailable: return .orange
        }
    }

    private func noteIcon(_ severity: CheckSeverity) -> String {
        switch severity {
        case .note: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .blocking: return "xmark.octagon.fill"
        }
    }

    private func noteColor(_ severity: CheckSeverity) -> Color {
        switch severity {
        case .note: return .accentColor
        case .warning: return .orange
        case .blocking: return .red
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
            .foregroundStyle(color)
    }
}

/// `sheet(item:)` needs Identifiable; an InstallPlan is a value snapshot, so
/// boxing it is enough and avoids making the model itself Identifiable.
private struct PlanBox: Identifiable {
    let id = UUID()
    let plan: InstallPlan
}

// MARK: - Key set panel

struct KeySetPanel: View {
    @ObservedObject var model: BatchInstallModel
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("深度检查密钥", systemImage: "key.fill")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    dismiss()
                } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }

            Text("结构检查不需要密钥。只有“深度检查”（验证 NCA 签名链与内容哈希）需要你自己从主机提取的 prod.keys。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: model.keySetLoaded ? "checkmark.seal.fill" : "exclamationmark.triangle")
                        .foregroundStyle(model.keySetLoaded ? .green : .orange)
                    Text(model.keySetPath ?? "尚未选择密钥文件")
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                if let error = model.keySetError {
                    Text(error).font(.system(size: 10)).foregroundStyle(.red)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))

            HStack(spacing: 10) {
                Button {
                    model.chooseKeySet()
                } label: {
                    Label(model.keySetPath == nil ? "选择 prod.keys" : "更换文件", systemImage: "folder")
                }
                if model.keySetPath != nil {
                    Button(role: .destructive) {
                        model.clearKeySet()
                    } label: { Text("移除") }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("隐私与边界").font(.system(size: 11, weight: .semibold))
                bullet("密钥只在本机读取，不上传、不写日志、不进报告。")
                bullet("校验引擎需要一个文件路径，因此检查期间会在系统临时目录放一份 0600 权限的临时副本，检查结束立即删除。")
                bullet("这个工作区不提供下载、密钥获取、签名绕过或固件修改。")
                bullet("固件镜像不是必需输入；缺新密钥代时结果会是“无法验证”，而不是“签名错误”。")
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 460)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").foregroundStyle(.secondary)
            Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
