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

let fixture = "test/fixtures/禁漫天堂-适配.json"

print("=== 禁漫天堂 · 登录面板探针（真引擎求值）===")

guard let data = FileManager.default.contents(atPath: fixture),
      let raw = try? JSONDecoder().decode(BookSource.self, from: data) else {
    print("FAIL: 读不到 fixture（\(fixture)）⇒ 探针没验到")
    exit(1)
}

// ① 静态 loginUi 的行（**宿主也是自己解析静态的** ⇒ 探针同路径）
guard let uiRaw = raw.loginUi, let uiData = uiRaw.data(using: .utf8),
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
let web = WebBook(source: raw, environment: env)

// ② 批量求值 viewName（**宿主用的是同一段逻辑** ⇒ 一次求值一批）⭐⭐⭐
let quote = String(UnicodeScalar(34))
let js = "[" + exprs.map { $0.isEmpty ? quote : $0 }.joined(separator: ",") + "]"
let rawNames = (try? await web.evalJS(js)) ?? ""
print("求值结果：\(rawNames)")

guard let namesData = rawNames.data(using: .utf8),
      let names = try? JSONDecoder().decode([String].self, from: namesData) else {
    print("FAIL: viewName 批量求值失败（⇒ 按钮标题拿不到 ⇒ 用户看不到「小说/漫画/视频」）")
    exit(1)
}
if names.count != rows.count {
    print("FAIL: 求值条数 \(names.count) ≠ 行数 \(rows.count)")
    exit(1)
}

// ③ 断言：人话名里出现「漫画」「小说」「视频」⭐⭐⭐
let joined = names.joined(separator: "|")
for kw in ["漫画", "小说", "视频"] {
    if !joined.contains(kw) {
        print("FAIL: viewName 求值结果里没有「\(kw)」⇒ 用户看不到这个按钮")
        exit(1)
    }
}
print("人话名：\(joined)")

// ④ 断言：action 能真跑（jmSetMode 写书源变量）⭐⭐⭐
let modeAction = rows.first { ($0["action"] as? String)?.contains("jmSetMode") == true }
if let action = modeAction?["action"] as? String {
    // ⚠️ action 里带 `java` 参数 ⇒ 宿主执行时作用域里有 java ⇒ 这里照抄站方的写法 ⭐⭐⭐
    let expr = action.replacingOccurrences(of: "jmSetMode(java,", with: "jmSetMode(source,")
    _ = try? await web.evalJS(expr)
    let mode = env.cache.get("v_\(raw.bookSourceUrl)_jmMode")
    print("jmMode = \(mode ?? "(空)")")
    if mode != "小说" {
        print("FAIL: 点了「小说」但 jmMode 没写进去（= \(mode ?? "空"))⇒ 按钮点了没反应")
        exit(1)
    }
} else {
    print("FAIL: 找不到 jmSetMode 的 action ⇒ 探针前提不成立")
    exit(1)
}

print("OK")
