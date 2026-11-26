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

import AppKit
import ApplicationServices

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

func keyStroke(_ code: CGKeyCode, flags: CGEventFlags = []) {
    let source = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
    down?.flags = flags
    up?.flags = flags
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
}

func typeText(_ text: String) {
    let source = CGEventSource(stateID: .hidSystemState)
    for scalar in text.unicodeScalars {
        var unit = UInt16(scalar.value)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
        up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

// MARK: - Harness

var passes: [String] = []
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

guard CommandLine.arguments.count > 1, let pid = pid_t(CommandLine.arguments[1]) else {
    print("usage: ax-scroll-list-test <pid>")
    exit(2)
}

let app = AXUIElementCreateApplication(pid)

func window(titled name: String) -> AXUIElement? {
    let list = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    return list.first { title($0) == name || stringValue($0) == name }
}

// MARK: - TC0: main window, then open the batch workspace from the toolbar

NSRunningApplication(processIdentifier: pid)?.activate(options: [])

let mainWindowName = "SwitchMTP Batch AX"
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
    keyStroke(0, flags: .maskCommand)      // ⌘A
    keyStroke(51)                          // delete
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
    keyStroke(0, flags: .maskCommand)
    keyStroke(51)
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

print("PASS \(passes.count)  FAIL \(failures.count)")
exit(failures.isEmpty ? 0 : 1)
