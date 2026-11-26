// SwitchMTP Batch — AX regression test for the scrolling plan list.
// Copyright (C) 2025 fratei
// SPDX-License-Identifier: GPL-2.0
//
// Drives a running instance of the app through the accessibility API and
// asserts the properties the scrolling list has to keep:
//
//   * the plan list carries no table semantics (no AXRow / AXCell / AXOutline),
//     which is the whole reason `List` was replaced by `ScrollView + VStack`;
//   * every package checkbox is an addressable AXButton with its own identifier;
//   * pressing those buttons actually flips the model (single item, whole group,
//     select all / none);
//   * the search field still filters, and clearing it restores the full list.
//
// Usage: ax-scroll-list-test <pid>       (see run-ax-scroll-list-test.sh)
// Exit status 0 = all cases passed.
//
// Synthetic input policy: every event this probe fabricates is addressed to the
// app under test alone — a `.privateState` source plus `postToPid`. Nothing is
// posted to `.cghidEventTap`, so the hardware cursor never moves and the probe
// never merges into the real HID state while a run is in progress.
//
// `AX_TEST_HID_CLICKS=1` restores the old HID-level click for the row-body
// cases (TC8.2/8.3). That path does move the physical cursor, so it stays
// opt-in and is never used by a default run.

import AppKit
import ApplicationServices

/// The process under test. Synthetic input is addressed to it alone.
let targetPID: pid_t = {
    guard CommandLine.arguments.count > 1, let pid = pid_t(CommandLine.arguments[1]) else {
        print("usage: ax-scroll-list-test <pid>")
        exit(2)
    }
    return pid
}()

/// Private source: `kCGEventSourceStatePrivate` keeps fabricated events out of
/// the hardware state that the real mouse and keyboard share.
let syntheticSource: CGEventSource? = {
    let source = CGEventSource(stateID: .privateState)
    if source == nil {
        print("FAIL  cannot create a private event source (grant Accessibility to this process)")
    }
    return source
}()

/// `AX_TEST_HID_CLICKS=1` is the only way this probe may touch the hardware
/// cursor. It exists for the row-body cases, where AppKit will not route a
/// delivered mouse event into the window's content.
let allowHIDClicks = ProcessInfo.processInfo.environment["AX_TEST_HID_CLICKS"] == "1"

/// CGWindowID of the window a synthetic click is aimed at. AppKit routes a
/// delivered mouse event through `windowNumber`, and events that never touched
/// the window server carry 0 unless this is filled in.
var syntheticClickWindow: Int?

/// Finds the CGWindowID whose bounds match an AX frame. Matching by geometry
/// avoids needing the window name, which requires screen-recording access.
func windowNumber(matching frame: CGRect) -> Int? {
    guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return nil }
    for info in list {
        guard let owner = info[kCGWindowOwnerPID as String] as? NSNumber,
              owner.int32Value == targetPID else { continue }
        guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let x = (bounds["X"] as? NSNumber)?.doubleValue,
              let y = (bounds["Y"] as? NSNumber)?.doubleValue,
              let w = (bounds["Width"] as? NSNumber)?.doubleValue,
              let h = (bounds["Height"] as? NSNumber)?.doubleValue,
              let number = (info[kCGWindowNumber as String] as? NSNumber)?.intValue
        else { continue }
        let rect = CGRect(x: x, y: y, width: w, height: h)
        if abs(rect.minX - frame.minX) <= 2, abs(rect.minY - frame.minY) <= 2,
           abs(rect.width - frame.width) <= 2, abs(rect.height - frame.height) <= 2 {
            return number
        }
    }
    return nil
}

// MARK: - AX helpers

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(el, name as CFString, &value)
    return err == .success ? value : nil
}

func role(_ el: AXUIElement) -> String {
    (attr(el, kAXRoleAttribute) as? String) ?? ""
}

func identifier(_ el: AXUIElement) -> String {
    (attr(el, "AXIdentifier") as? String) ?? ""
}

func description(_ el: AXUIElement) -> String {
    (attr(el, kAXDescriptionAttribute) as? String) ?? ""
}

func title(_ el: AXUIElement) -> String {
    (attr(el, kAXTitleAttribute) as? String) ?? ""
}

func help(_ el: AXUIElement) -> String {
    (attr(el, kAXHelpAttribute) as? String) ?? ""
}

func stringValue(_ el: AXUIElement) -> String {
    if let s = attr(el, kAXValueAttribute) as? String { return s }
    if let n = attr(el, kAXValueAttribute) as? NSNumber { return n.stringValue }
    return ""
}

func children(_ el: AXUIElement) -> [AXUIElement] {
    (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func frame(_ el: AXUIElement) -> CGRect? {
    guard let v = attr(el, kAXPositionAttribute) else { return nil }
    guard let s = attr(el, kAXSizeAttribute) else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(v as! AXValue, .cgPoint, &point)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: point, size: size)
}

func press(_ el: AXUIElement) -> Bool {
    AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
}

/// Depth-first walk with a visit cap, so a runaway tree cannot hang the test.
func walk(_ root: AXUIElement, depth: Int = 0, _ visit: (AXUIElement, Int) -> Void) {
    guard depth < 40 else { return }
    visit(root, depth)
    for child in children(root) { walk(child, depth: depth + 1, visit) }
}

func allElements(_ root: AXUIElement) -> [AXUIElement] {
    var out: [AXUIElement] = []
    walk(root) { el, _ in out.append(el) }
    return out
}

func find(_ root: AXUIElement, where predicate: (AXUIElement) -> Bool) -> AXUIElement? {
    var hit: AXUIElement?
    walk(root) { el, _ in
        if hit == nil, predicate(el) { hit = el }
    }
    return hit
}

func findAll(_ root: AXUIElement, where predicate: (AXUIElement) -> Bool) -> [AXUIElement] {
    var out: [AXUIElement] = []
    walk(root) { el, _ in if predicate(el) { out.append(el) } }
    return out
}

// MARK: - Synthetic typing (the search field only updates on real key events)

/// Sends key events to the app under test only. The window server never sees
/// them, so the hardware cursor and the real keyboard keep working throughout.
func keyStroke(_ code: CGKeyCode, flags: CGEventFlags = []) {
    let down = CGEvent(keyboardEventSource: syntheticSource, virtualKey: code, keyDown: true)
    let up = CGEvent(keyboardEventSource: syntheticSource, virtualKey: code, keyDown: false)
    down?.flags = flags
    up?.flags = flags
    down?.postToPid(targetPID)
    up?.postToPid(targetPID)
}

func typeText(_ text: String) {
    for scalar in text.unicodeScalars {
        var unit = UInt16(scalar.value)
        let down = CGEvent(keyboardEventSource: syntheticSource, virtualKey: 0, keyDown: true)
        let up = CGEvent(keyboardEventSource: syntheticSource, virtualKey: 0, keyDown: false)
        down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
        up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
        down?.postToPid(targetPID)
        up?.postToPid(targetPID)
    }
}

/// A click at a global screen point, delivered to the app under test only.
/// Required for row bodies: they carry a tap gesture but no AX element of their
/// own to press. The event never enters the HID stream, so the physical cursor
/// stays where the user left it.
func clickPoint(_ point: CGPoint) {
    let move = CGEvent(mouseEventSource: syntheticSource, mouseType: .mouseMoved,
                       mouseCursorPosition: point, mouseButton: .left)
    let down = CGEvent(mouseEventSource: syntheticSource, mouseType: .leftMouseDown,
                       mouseCursorPosition: point, mouseButton: .left)
    let up = CGEvent(mouseEventSource: syntheticSource, mouseType: .leftMouseUp,
                     mouseCursorPosition: point, mouseButton: .left)
    if let window = syntheticClickWindow {
        for event in [move, down, up] {
            event?.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window))
            event?.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window))
        }
    }
    move?.postToPid(targetPID)
    down?.postToPid(targetPID)
    up?.postToPid(targetPID)
}

/// Opt-in HID click, used only when `AX_TEST_HID_CLICKS=1`. This moves the
/// physical cursor and merges into the real HID state; nothing else in this
/// probe is allowed to.
func hidClickPoint(_ point: CGPoint) {
    let source = CGEventSource(stateID: .hidSystemState)
    CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
            mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
            mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
            mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
}

var passes: [String] = []
var skips: [String] = []
var failures: [String] = []

func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        passes.append(name)
        print("PASS  \(name)")
    } else {
        failures.append(name)
        print("FAIL  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

/// Cases this run cannot cover at all, with the reason. A skip never counts as
/// a pass and never fails the suite; it is printed so the gap stays visible.
func skip(_ name: String, _ reason: String) {
    skips.append(name)
    print("SKIP  \(name) — \(reason)")
}

func waitUntil(_ timeout: TimeInterval = 3, _ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return predicate()
}

/// "已选 43 / 44 项 …" → (43, 44)
func selectionSummary(in root: AXUIElement) -> (selected: Int, total: Int)? {
    let texts = findAll(root) { el in
        role(el) == kAXStaticTextRole as String && stringValue(el).contains("已选")
    }
    guard let el = texts.first else { return nil }
    let pattern = try! NSRegularExpression(pattern: "已选\\s*([0-9]+)\\s*/\\s*([0-9]+)")
    let value = stringValue(el)
    let range = NSRange(value.startIndex..., in: value)
    guard let match = pattern.firstMatch(in: value, range: range),
          match.numberOfRanges == 3,
          let a = Range(match.range(at: 1), in: value),
          let b = Range(match.range(at: 2), in: value) else { return nil }
    return (Int(value[a]) ?? -1, Int(value[b]) ?? -1)
}

func groupBoxes(in root: AXUIElement) -> [AXUIElement] {
    findAll(root) { identifier($0).hasPrefix("group-checkbox-") }
}

func packageBoxes(in root: AXUIElement) -> [AXUIElement] {
    findAll(root) { identifier($0).hasPrefix("package-checkbox-") }
}

let app = AXUIElementCreateApplication(targetPID)

func window(titled name: String) -> AXUIElement? {
    let list = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    return list.first { title($0) == name || stringValue($0) == name }
}

// MARK: - TC0: main window, then open the batch workspace from the toolbar

// The app is deliberately not activated: every assertion goes through the
// accessibility tree, which does not require the app to be frontmost. Staying
// unprompted is what keeps a run from stealing the user's focus.

// The release build's main window is "SwitchMTP Batch"; the test builds that
// carried a suffix ("… AX") still match this prefix, so the suite runs against
// either one without editing.
let mainWindowName = ((attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [])
    .map(title)
    .first { $0.hasPrefix("SwitchMTP Batch") } ?? "SwitchMTP Batch"
let workspaceName = "批量安装"

check("TC0.1 主窗口存在", waitUntil(5) { window(titled: mainWindowName) != nil },
      "windows=\((attr(app, kAXWindowsAttribute) as? [AXUIElement])?.map(title) ?? [])")

guard let main = window(titled: mainWindowName) else {
    print(failures.isEmpty ? "PASS 0  FAIL 1" : "PASS \(passes.count)  FAIL \(failures.count)")
    exit(1)
}

if window(titled: workspaceName) == nil {
    let openButton = find(main) { el in
        role(el) == kAXButtonRole as String && description(el) == "批量安装"
    }
    if let openButton { _ = press(openButton) }
}

check("TC0.2 批量安装窗口能打开", waitUntil(8) { window(titled: workspaceName) != nil })

guard let workspace = window(titled: workspaceName) else {
    print("PASS \(passes.count)  FAIL \(failures.count + 1)")
    exit(1)
}

check("TC1.0 夹具已载入（44 个包）",
      waitUntil(15) { selectionSummary(in: workspace)?.total == 44 },
      "summary=\(String(describing: selectionSummary(in: workspace)))")

// MARK: - TC1: expand all so every package row is materialised

if let expandAll = find(workspace, where: { help($0).contains("展开/收起全部") }) {
    _ = press(expandAll)
} else {
    check("TC1.0 找到展开全部按钮", false)
}

let rowsReady = waitUntil(5) { packageBoxes(in: workspace).count >= 44 }
check("TC1.1 展开全部后 44 个包复选框都进了 AX 树", rowsReady,
      "count=\(packageBoxes(in: workspace).count)")

// MARK: - TC2: no table semantics anywhere under the plan list

let scrollAreas = findAll(workspace) { role($0) == kAXScrollAreaRole as String }
let listArea = scrollAreas.max { (frame($0)?.height ?? 0) < (frame($1)?.height ?? 0) }
let listRoot = listArea ?? workspace

let tableNodes = findAll(listRoot) { el in
    let r = role(el)
    return r == "AXRow" || r == "AXCell" || r == "AXOutline" || r == "AXTable"
}
check("TC2.1 清单里没有 AXRow / AXCell / AXOutline / AXTable",
      tableNodes.isEmpty,
      "命中 \(tableNodes.count): \(tableNodes.prefix(3).map { "\(role($0)) \(identifier($0))" })")

// MARK: - TC3: every package checkbox is an addressable button

let listRegion = findAll(workspace) { el in
    identifier(el) == "plan-list" || description(el) == "批量安装清单"
}
let regionRole = listRegion.first.map(role) ?? ""
check("TC2b.1 清单容器带名称与说明", !listRegion.isEmpty,
      "count=\(listRegion.count) role=\(regionRole)")
check("TC2b.2 清单容器是可命名的容器", ["AXGroup", "AXList"].contains(regionRole),
      "role=\(regionRole)")

let boxes = packageBoxes(in: workspace)
let badBoxes = boxes.filter { el in
    role(el) != kAXButtonRole as String
        || identifier(el).isEmpty
        || (attr(el, kAXDescriptionAttribute) as? String ?? "").isEmpty
}
check("TC3.1 每个包复选框都是带 identifier 的 AXButton",
      boxes.count == 44 && badBoxes.isEmpty,
      "count=\(boxes.count) bad=\(badBoxes.prefix(3).map(identifier))")

// MARK: - TC4: a single checkbox press flips exactly one package

var sample: AXUIElement? = boxes.first
let before = selectionSummary(in: workspace)
let beforeValue = sample.map(stringValue) ?? ""

if let sample {
    let pressed = press(sample)
    let flipped = waitUntil(2) {
        selectionSummary(in: workspace)?.selected == (before?.selected ?? -1) - 1
    }
    let afterValue = stringValue(sample)
    check("TC4.1 单包 AXPress 只减一项", pressed && flipped,
          "before=\(before?.selected ?? -1) after=\(selectionSummary(in: workspace)?.selected ?? -1)")
    check("TC4.2 该行的 value 已翻转", afterValue != beforeValue,
          "before=\(beforeValue) after=\(afterValue)")

    _ = press(sample)
    check("TC4.3 再按一次恢复", waitUntil(2) {
        selectionSummary(in: workspace)?.selected == before?.selected
    }, "selected=\(selectionSummary(in: workspace)?.selected ?? -1)")
} else {
    check("TC4.1 单包 AXPress 只减一项", false, "没有包复选框")
}

// MARK: - TC5: a group checkbox press clears the whole group, and restores

if let group = groupBoxes(in: workspace).first {
    let total = selectionSummary(in: workspace)?.total ?? 0
    let before = selectionSummary(in: workspace)?.selected ?? 0
    let memberCount = Int(stringValue(group).split(separator: "/").first ?? "0") ?? 0

    _ = press(group)
    let cleared = waitUntil(3) {
        selectionSummary(in: workspace)?.selected == before - memberCount
    }
    check("TC5.1 组 AXPress 影响整组可选项", cleared,
          "members=\(memberCount) before=\(before) after=\(selectionSummary(in: workspace)?.selected ?? -1)")
    check("TC5.2 组计数变成 0/N", stringValue(group).hasPrefix("0/\(memberCount)"),
          "value=\(stringValue(group))")

    _ = press(group)
    check("TC5.3 组再按一次恢复", waitUntil(3) {
        selectionSummary(in: workspace)?.selected == total
    }, "selected=\(selectionSummary(in: workspace)?.selected ?? -1) total=\(total)")
} else {
    check("TC5.1 组 AXPress 影响整组可选项", false, "没有组复选框")
}

// MARK: - TC6: toolbar select-all / select-none

if let noneAll = find(workspace, where: { role($0) == kAXButtonRole as String && description($0) == "全不选" }),
   let allAll = find(workspace, where: { role($0) == kAXButtonRole as String && description($0) == "全选" }) {
    _ = press(noneAll)
    check("TC6.1 全不选清零", waitUntil(3) { selectionSummary(in: workspace)?.selected == 0 },
          "selected=\(selectionSummary(in: workspace)?.selected ?? -1)")
    check("TC6.2 包复选框同步为未选择",
          packageBoxes(in: workspace).allSatisfy { stringValue($0) == "未选择" })
    _ = press(allAll)
    check("TC6.3 全选恢复", waitUntil(3) {
        let s = selectionSummary(in: workspace)
        return s != nil && s!.selected == s!.total
    }, "selected=\(selectionSummary(in: workspace)?.selected ?? -1)")
} else {
    check("TC6.1 全不选清零", false, "找不到全选/全不选按钮")
}

// MARK: - TC7: search filters, clearing restores

let baselineGroups = groupBoxes(in: workspace).count
let searchField = find(workspace) { role($0) == kAXTextFieldRole as String }
    ?? find(workspace) { el in (attr(el, "AXPlaceholderValue") as? String)?.contains("搜索") == true }

if let searchField {
    AXUIElementSetAttributeValue(searchField, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    Thread.sleep(forTimeInterval: 0.2)
    // ⌘A is a menu key equivalent and needs a key window; delete does not.
    for _ in 0..<12 { keyStroke(51) }
    typeText("塞尔达")

    let filtered = waitUntil(3) {
        let groups = groupBoxes(in: workspace)
        return !groups.isEmpty && groups.count < baselineGroups
    }
    check("TC7.1 搜索后只剩匹配组", filtered,
          "groups=\(groupBoxes(in: workspace).count) baseline=\(baselineGroups)")
    check("TC7.2 剩下的组都命中关键字",
          groupBoxes(in: workspace).allSatisfy { description($0).contains("塞尔达") })

    AXUIElementSetAttributeValue(searchField, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    for _ in 0..<12 { keyStroke(51) }
    check("TC7.3 清空搜索恢复全部组", waitUntil(4) {
        groupBoxes(in: workspace).count == baselineGroups
    }, "groups=\(groupBoxes(in: workspace).count) baseline=\(baselineGroups)")

    // Leave the run in the state the user expects.
    if let allAll = find(workspace, where: { role($0) == kAXButtonRole as String && description($0) == "全选" }) {
        _ = press(allAll)
    }
} else {
    check("TC7.1 搜索后只剩匹配组", false, "找不到搜索框")
}

// MARK: - TC8: a collapsed group row opens the game overview and expands it

if let collapseAll = find(workspace, where: { help($0).contains("展开/收起全部") }) {
    _ = press(collapseAll)
}
check("TC8.1 收起全部后包复选框已离场",
      waitUntil(3) { packageBoxes(in: workspace).isEmpty },
      "count=\(packageBoxes(in: workspace).count)")

// TC8 covers two things: a collapsed group row opens the overview and expands
// itself (row body only — no AX element of its own), and the list expands and
// collapses again. The row-body click needs a HID-level event; AppKit will not
// route a delivered one into the window's content, so a default run skips it
// and verifies expand/collapse through the chevron button instead.
if allowHIDClicks {
    print("      AX_TEST_HID_CLICKS=1 — the physical cursor will move for TC8.2/8.3")
    // HID clicks only land on a key window in the active app. This is the one
    // place a run is allowed to take focus, and only when explicitly opted in.
    NSRunningApplication(processIdentifier: targetPID)?.activate(options: [])
    AXUIElementPerformAction(workspace, kAXRaiseAction as CFString)
    Thread.sleep(forTimeInterval: 0.4)
    syntheticClickWindow = frame(workspace).flatMap { windowNumber(matching: $0) }
    print("      click window=\(syntheticClickWindow.map(String.init) ?? "nil")")
    if let group = groupBoxes(in: workspace).first, let groupFrame = frame(group) {
        let point = CGPoint(x: groupFrame.maxX + 150, y: groupFrame.midY)
        // A single click must select and show the overview without expanding.
        hidClickPoint(point)
        let overviewOnce = waitUntil(2) {
            find(workspace) { el in
                role(el) == kAXStaticTextRole as String && stringValue(el).contains("包含的安装包")
            } != nil
        }
        check("TC8.2 单击组行只显示概览", overviewOnce && packageBoxes(in: workspace).isEmpty,
              "overview=\(overviewOnce) rows=\(packageBoxes(in: workspace).count)")
        // Expansion is on a double click now.
        hidClickPoint(point)
        Thread.sleep(forTimeInterval: 0.12)
        hidClickPoint(point)
        check("TC8.3 双击组行展开该组", waitUntil(3) { !packageBoxes(in: workspace).isEmpty },
              "count=\(packageBoxes(in: workspace).count)")
        hidClickPoint(point)
        Thread.sleep(forTimeInterval: 0.12)
        hidClickPoint(point)
        check("TC8.4 再双击收起该组", waitUntil(3) { packageBoxes(in: workspace).isEmpty },
              "count=\(packageBoxes(in: workspace).count)")
    } else {
        check("TC8.2 单击组行只显示概览", false, "没有组复选框可比对")
    }
} else {
    skip("TC8.2 单击组行只显示概览", "行本体没有常驻 AX action；默认运行不碰硬件光标")
    skip("TC8.3 双击组行展开该组", "同上")
    if let expand = findAll(workspace, where: { identifier($0).hasPrefix("group-expand-") }).first {
        _ = press(expand)
        check("TC8.4 展开箭头展开该组", waitUntil(3) { !packageBoxes(in: workspace).isEmpty },
              "count=\(packageBoxes(in: workspace).count)")
        _ = press(expand)
        check("TC8.5 展开箭头再收起该组", waitUntil(3) { packageBoxes(in: workspace).isEmpty },
              "count=\(packageBoxes(in: workspace).count)")
    } else {
        check("TC8.4 展开箭头展开该组", false, "找不到展开箭头")
    }
}

if let expandAll = find(workspace, where: { help($0).contains("展开/收起全部") }) {
    _ = press(expandAll)
}
check("TC8.6 再展开恢复 44 行", waitUntil(3) { packageBoxes(in: workspace).count >= 44 },
      "count=\(packageBoxes(in: workspace).count)")

print("PASS \(passes.count)  SKIP \(skips.count)  FAIL \(failures.count)")
exit(failures.isEmpty ? 0 : 1)
