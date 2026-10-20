// Swift 侧对拍：读 test/fixtures/scroll-core-cases.json（由 JS 原版生成），
// 用 ReaderScrollCore.swift 跑同一批用例，逐条比对。
//
// ⚠️ 这是**真对拍**（不是源码 grep）：JS 原版跑出来的期望值 → Swift 实现跑一遍 →
//    两边都序列化成 JSON（key 排序）→ 字符串比较。
//
// 编译运行（CI 里）：
//   swiftc -O test/scroll-core-parity.swift \
//          QiReaderLite/Features/Reader/Paging/ReaderScrollCore.swift \
//          -o /tmp/scroll-core-parity && /tmp/scroll-core-parity .
//
// ReaderScrollCore.swift 只 import Foundation，所以在 macOS runner 上能直接编。
import Foundation

// MARK: - JSON 取值助手

func jStr(_ any: Any?) -> String? {
    if any is NSNull { return nil }
    return any as? String
}
func jDouble(_ any: Any?) -> Double? {
    if any is NSNull { return nil }
    if let d = any as? Double { return d }
    if let i = any as? Int { return Double(i) }
    return nil
}
func jInt(_ any: Any?) -> Int? {
    if any is NSNull { return nil }
    if let i = any as? Int { return i }
    if let d = any as? Double { return Int(d) }
    return nil
}
func jBool(_ any: Any?) -> Bool? {
    if any is NSNull { return nil }
    return any as? Bool
}
func jArray(_ any: Any?) -> [Any]? {
    if any is NSNull { return nil }
    return any as? [Any]
}

/// 统一转成 key 排序的 JSON 文本，便于跟 expected 逐字符比
func jsonText(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let d = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let s = String(data: d, encoding: .utf8) else {
        return "INVALID"
    }
    return s
}

// MARK: - 跑一个用例，返回 JSON 兼容的值

func runCase(_ c: [String: Any]) -> Any {
    let fn = jStr(c["fn"]) ?? ""
    let args = jArray(c["args"]) ?? []
    func arg(_ i: Int) -> Any? { return i < args.count ? args[i] : nil }

    switch fn {
    case "chooseTrim":
        let r = ReaderScrollCore.chooseTrimRemovalSide(
            firstIndex: jDouble(arg(0)),
            lastIndex: jDouble(arg(1)),
            anchorIndex: jDouble(arg(2)),
            mode: jStr(arg(3)))
        return r

    case "trimWindow":
        let idx = (jArray(arg(0)) ?? []).compactMap { jInt($0) }
        let r = ReaderScrollCore.trimChapterWindow(
            indices: idx,
            maxWindow: jInt(arg(1)) ?? 0,
            anchorIndex: jInt(arg(2)),
            mode: jStr(arg(3)))
        return ["kept": r.kept, "removed": r.removed]

    case "shouldReport":
        let r = ReaderScrollCore.shouldReportProgress(
            includeProgress: jBool(arg(0)) ?? false,
            chapterChanged: jBool(arg(1)) ?? false,
            force: jBool(arg(2)) ?? false,
            lastProgressAt: jDouble(arg(3)) ?? 0,
            now: jDouble(arg(4)) ?? 0)
        return r

    case "viewport":
        let r = ReaderScrollCore.viewportAnchorAdjustment(
            anchorTop: jDouble(arg(0)),
            currentTop: jDouble(arg(1)),
            scrollTop: jDouble(arg(2)))
        return ["delta": r.delta, "targetScrollTop": r.targetScrollTop, "shouldRestore": r.shouldRestore]

    case "titleHeight":
        return ReaderScrollCore.normalizedTitleHeight(jDouble(arg(0)))

    default:
        return "?unknown:\(fn)"
    }
}

// MARK: - main

let repoRoot = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath
let fixture = URL(fileURLWithPath: repoRoot)
    .appendingPathComponent("test/fixtures/scroll-core-cases.json")

guard let data = try? Data(contentsOf: fixture),
      let root = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
    FileHandle.standardError.write("❌ 读不到用例文件: \(fixture.path)\n".data(using: .utf8)!)
    exit(2)
}

var bad = 0
for c in root {
    let name = jStr(c["name"]) ?? "?"
    guard let expected = c["expected"] else { continue }
    let got = runCase(c)
    let gotText = jsonText(got)
    let wantText = jsonText(expected)
    if gotText != wantText {
        bad += 1
        print("✗ \(name)\n   got  = \(gotText)\n   want = \(wantText)")
    }
}

if bad == 0 {
    print("✅ Swift 与 JS 原版行为一致：\(root.count) 条用例全过")
    exit(0)
} else {
    print("❌ \(bad)/\(root.count) 条不一致")
    exit(1)
}
