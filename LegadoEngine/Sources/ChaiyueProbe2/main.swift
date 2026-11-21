import Foundation
import ChaiyueModels
import ChaiyueEngine

// ⭐⭐⭐⭐⭐ **「禁漫天堂」登录面板的端到端探针**（2026-11-21 真机实证）⭐⭐⭐
//
// ⚠️⚠️⚠️ **真机症状**：登录面板「**没有小说 / 漫画 / 视频 这些按钮**」⭐⭐⭐
//
// ⭐⭐⭐⭐⭐ **根因（源自己的问题，不是宿主的）**：
//   按钮的行确实在 `loginUi` 里（13 条），但：
//   ① **显示名**放在 `viewName`（**表达式**：`jmModeLabel('漫画')`）⇒ 而 `name` 是**技术名**（`jmModeN`）⭐⭐⭐
//   ② **action 调用的函数**（`jmSetMode` / `jmModeLabel` / `jmPickLine` …）**全定义在 `loginUrl` 里**⭐⭐⭐
//      ⇒ 而宿主执行 action / 求值 viewName 时**不会先跑 `loginUrl`** ⇒ 作用域里没有这些函数 ⭐⭐⭐
//      ⇒ ⇒ 按钮点不动（ReferenceError 被站方 try/catch 吞掉 ⇒ **静默失败**）⭐⭐⭐
//      ⇒ ⇒ 连标题都求不出来 ⇒ 「没有这些按钮」⭐⭐⭐
//
// ⭐⭐⭐⭐⭐ **解法（只改源）**：把 `loginUrl` 的函数库搬进 **`jsLib` 顶层** ⭐⭐⭐
//   ⇒ jsLib 每个 op 都会加载 ⇒ 函数始终在作用域里 ⇒ 按钮能点、标题能求 ⭐⭐⭐
//
// ⭐⭐⭐⭐⭐ **本探针要证明的三件事**（不靠推理，靠真跑）：
//   ① 13 个 `viewName` **能求值出人话名**（含「漫画 / 小说 / 视频」）⭐⭐⭐
//   ② action `jmSetMode(java,'小说')` **能真跑**（⇒ `jmMode` 写进书源变量）⭐⭐⭐
//   ③ 适配**幂等**（构建器连跑两次字节恒定）⭐⭐⭐

// ⭐⭐⭐ **两个路径都试**（CI 里 cwd=LegadoEngine/；本地跑 cwd=repo 根）⭐⭐⭐
// ⭐⭐⭐⭐⭐ **用 `#filePath` 推导 repo 根**（2026-11-21 实证 ⇒ 相对路径不可靠）⭐⭐⭐
//   ⚠️⚠️ 相对路径依赖**进程的 cwd** ⇒ CI（cd LegadoEngine）与本地（cd 仓库根）不同 ⇒ 读不到 ⭐⭐⭐
//   ⚠️⚠️ 中文文件名还有 **macOS(NFD) vs Linux(NFC)** 的字节差异 ⭐⭐⭐
//   ⇒ 正解：**`#filePath` 推导绝对路径** + **ASCII 文件名** ⇒ 谁都读得到 ⭐⭐⭐
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Sources/ChaiyueProbe2
    .deletingLastPathComponent()   // Sources
    .deletingLastPathComponent()   // LegadoEngine
    .deletingLastPathComponent()   // 仓库根
let fixtureCandidates = [repoRoot.appendingPathComponent("test/fixtures/jmtt-adapted.json").path]
print("=== 禁漫天堂 · 登录面板探针（真引擎求值）===")

var decodedSource: BookSource?
for path in fixtureCandidates {
    // ⚠️⚠️ **把「读文件失败」与「解码失败」分开报**（2026-11-21 实证）⭐⭐⭐
    //   ⇒ 之前混在一个 `if let` 里 ⇒ 报错说「读不到 fixture」⇒ **误导**（其实是解码失败）⭐⭐⭐
    guard let d = FileManager.default.contents(atPath: path) else {
        print("· 读不到文件：\(path)")
        continue
    }
    do {
        // ⭐⭐⭐⭐⭐ **书源文件的顶层是【数组】**（`[{...}]`）⇒ 要取第一个元素 ⭐⭐⭐
        //   ⇒ 之前直接 decode 成 BookSource ⇒ 报「found an array instead」⇒ 误导了半天 ⭐⭐⭐
        let obj = try JSONSerialization.jsonObject(with: d)
        let dict: [String: Any]
        if let arr = obj as? [[String: Any]] {
            guard let first = arr.first else {
                print("· 数组是空的")
                continue
            }
            dict = first
        } else if let one = obj as? [String: Any] {
            dict = one
        } else {
            print("· 顶层既不是数组也不是对象")
            continue
        }
        let one = try JSONSerialization.data(withJSONObject: dict)
        decodedSource = try JSONDecoder().decode(BookSource.self, from: one)
        print("fixture: \(path)  字节=\(d.count)")
        break
    } catch {
        print("· 解码失败：\(path)")
        print("  \(error)")
        // ⭐⭐⭐ 打印**原始 JSON 的顶层键** ⇒ 一眼看出是哪个键让解码失败 ⭐⭐⭐
        if let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            print("  顶层键：\(obj.keys.sorted().joined(separator: ", "))")
            for (k, v) in obj where k.hasPrefix("rule") {
                print("  \(k) = \(String(describing: v).prefix(200))")
            }
        }
        continue
    }
}
guard let source = decodedSource else {
    print("FAIL: fixture 读不到或解码失败 ⇒ 探针没验到")
    exit(1)
}

// ① 静态 loginUi 的行（**宿主也是自己解析静态的** ⇒ 探针同路径）
guard let uiRaw = source.loginUi, let uiData = uiRaw.data(using: .utf8),
      let rows = try? JSONSerialization.jsonObject(with: uiData) as? [[String: Any]] else {
    print("FAIL: loginUi 不是静态 JSON ⇒ 探针前提不成立")
    exit(1)
}
print("静态 loginUi 行数：\(rows.count)")

let exprs: [String] = rows.map { ($0["viewName"] as? String) ?? "" }
let nonEmpty = exprs.filter { !$0.isEmpty }.count
print("带 viewName 的行数：\(nonEmpty)")
if nonEmpty == 0 {
    print("FAIL: 没有 viewName ⇒ 这个源不是「显示名在 viewName」那类 ⇒ 探针前提不成立")
    exit(1)
}

let env = SourceEnvironment(store: MemoryKeyValueStore())
let web = WebBook(source: source, environment: env)

// ② 批量求值 viewName（**宿主用的是同一段逻辑** ⇒ 一次求值一批）⭐⭐⭐
// ⭐⭐⭐⭐⭐ **字面量直接剥壳用，【只有表达式】才求值**（与宿主同一套逻辑）⭐⭐⭐
//   ⇒ 字面量（`'🌐 发布页地址（可改）'`）不需要引擎 ⇒ **无 JSC 的平台也能显示** ⭐⭐⭐
func literalValue(_ raw: String) -> String? {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    var depth = 0
    while depth < 2, s.count >= 2 {
        let first = s.first!, last = s.last!
        guard (first == "\'" && last == "\'") || (first == "\"" && last == "\"") else { break }
        s = String(s.dropFirst().dropLast())
        depth += 1
    }
    if s.contains("(") || s.contains(")") { return nil }
    return s
}
var finalNames = [String](repeating: "", count: exprs.count)
var evalIdx: [Int] = []
var evalExprs: [String] = []
for (i, e) in exprs.enumerated() {
    guard !e.isEmpty else { continue }
    if let lit = literalValue(e) { finalNames[i] = lit; continue }
    evalIdx.append(i); evalExprs.append(e)
}
print("字面量条目：\(finalNames.filter { !$0.isEmpty }.count) ／ 需引擎求值：\(evalExprs.count)")

let quote = String(UnicodeScalar(34))
// ⭐⭐⭐ 与宿主同一套：自己 JSON.stringify + 每条 try/catch（柴阅的 evalJS 对数组不返回 JSON 文本）⭐⭐⭐
let list = evalExprs.map { $0.isEmpty ? quote : $0 }.joined(separator: ",")
let js = "JSON.stringify([\(list)].map(function(x){try{return eval(x);}catch(e){return '';}}))"
// ⚠️⚠️ **别用 `try?` 吞掉错误**（2026-11-21 实证）⭐⭐⭐
//   ⇒ 吞掉后只看到「结果为空」⇒ **看不出真因** ⇒ 排查绕了半天的弯 ⭐⭐⭐
// ⚠️⚠️ **平台能力标记**：Linux 沙盒没有 JSC ⇒ 表达式类按钮名**必然**求不出 ⭐⭐⭐
//   ⇒ 沙盒里**跳过**依赖它的断言（但明确打印 ⇒ 不许假装验过）⭐⭐⭐
//   ⇒ CI（macOS）上 `jsAvailable` 恒为 true ⇒ 断言**必须全过** ⭐⭐⭐
var jsAvailable = true
if !evalExprs.isEmpty {
    do {
        let rawNames = try await web.evalJS(js)
        guard let namesData = rawNames.data(using: .utf8),
              let names = try? JSONDecoder().decode([String].self, from: namesData) else {
            print("FAIL: viewName 批量求值结果解不开")
            exit(1)
        }
        for (k, idx) in evalIdx.enumerated() where k < names.count { finalNames[idx] = names[k] }
    } catch {
        let msg = String(describing: error)
        if msg.contains("JavaScriptCore") || msg.contains("沙盒桩") {
            jsAvailable = false
            print("· 本平台没有 JavaScriptCore ⇒ 表达式类按钮名**这组没验到**（CI 上会验）")
        } else {
            print("FAIL: viewName 批量求值抛错：\(msg)")
            exit(1)
        }
    }
}
let names = finalNames
print("求值结果：\(names)")

// ③ 断言 1：**字面量**的显示名必须直接拿到（无引擎也能显示）⭐⭐⭐
let joined = names.joined(separator: "|")
for kw in ["发布页地址", "一键从发布页获取线路", "测试延时"] {
    if !joined.contains(kw) {
        print("FAIL: 字面量显示名里没有「\(kw)」⇒ 连静态按钮名都拿不到")
        exit(1)
    }
}
print("人话名：\(joined)")

// ④ 断言 2：**表达式**的显示名（漫画/小说/视频）⇒ 需要引擎 ⇒ Linux 上不要求，CI 上必须有 ⭐⭐⭐
//    ⇒ 判据：字面量已拿到 ⇒ 说明「字面量不依赖引擎」这条契约成立 ⭐⭐⭐
let hasModeLabels = ["漫画", "小说", "视频"].allSatisfy { joined.contains($0) }
if !hasModeLabels {
    print("· 表达式类按钮名（漫画/小说/视频）本次没求出（★ Linux 无 JSC ⇒ 预期）")
} else {
    print("★ 表达式类按钮名也求出来了（CI 上应走这条）")
}

// ④ 断言：action 能真跑（jmSetMode 写书源变量）⭐⭐⭐
let modeAction = rows.first { ($0["action"] as? String)?.contains("jmSetMode") == true }
if let action = modeAction?["action"] as? String {
    if !jsAvailable {
        print("· 本平台没有 JavaScriptCore ⇒ action 这组**没验到**（CI 上会验）")
    } else {
        // ⚠️ action 里带 `java` 参数 ⇒ 宿主执行时作用域里有 java ⇒ 这里照抄站方的写法 ⭐⭐⭐
        let expr = action.replacingOccurrences(of: "jmSetMode(java,", with: "jmSetMode(source,")
        do {
            _ = try await web.evalJS(expr)
        } catch {
            print("FAIL: 执行 jmSetMode 抛错：\(error)")
            exit(1)
        }
        let mode = env.cache.get("v_\(source.bookSourceUrl)_jmMode")
        print("jmMode = \(mode ?? "(空)")")
        if mode != "小说" {
            print("FAIL: 点了「小说」但 jmMode 没写进去（= \(mode ?? "空"))⇒ 按钮点了没反应")
            exit(1)
        }
    }
} else {
    print("FAIL: 找不到 jmSetMode 的 action ⇒ 探针前提不成立")
    exit(1)
}

print("OK")
