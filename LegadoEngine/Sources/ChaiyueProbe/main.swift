import Foundation
import ChaiyueModels
import ChaiyueEngine

// ⭐⭐⭐⭐⭐ **登录表单探针**（2026-11-21 真机「登录界面没按钮」实证）⭐⭐⭐
//
// ⚠️⚠️⚠️ **为什么要有这个可执行探针**：
//   真机症状：有些书源点进登录面板 ⇒ **一个按钮都没有** ⭐⭐⭐
//   ⇒ 根因：站方的 `loginUi` 常常是 **`@js:` / `<js>` 薄壳**（正文在 jsLib 里）⭐⭐⭐
//     ⇒ 轻阅自己解析只能吃**静态 JSON** ⇒ 解析失败 ⇒ **面板空白** ⭐⭐⭐
//   ⇒ 柴阅的 `resolveLoginRows` 会**先跑 loginJs、再求值 loginUi** ⇒ 行拿得到 ⭐⭐⭐
//
// ⭐⭐⭐⭐⭐ **本探针要证明的那件事**（不靠推理，靠真跑）：
//   **「`@js:` 形式的 loginUi ⇒ 柴阅能解析出按钮行」** ⭐⭐⭐
//   ⇒ 沙盒 Linux 没有 JSC ⇒ **只能靠 CI（macOS）跑这个探针** ⭐⭐⭐
//
// ⭐⭐⭐ **为什么用合成 fixture 而不是真源**：
//   真源 jsLib 有 1.1MB ⇒ 不适合进仓库 ⇒ 而「loginUi 是 `@js:`」这件事**用合成源就能证明** ⭐⭐⭐
//   ⇒ 合成 fixture 放在 `LegadoEngine/Tests/Fixtures/`（或本文件内联）⇒ 自包含 ⇒ CI 必跑 ⭐⭐⭐

// ── 合成源：loginUi 是 `@js:` 薄壳 + jsLib 里定义辅助函数 ──────────────────
let jsLib = """
function _probeRows() {
  var rows = [];
  rows.push({name: '账号', type: 'text'});
  rows.push({name: '密码', type: 'password'});
  rows.push({name: '登录', type: 'button', action: 'login(true)'});
  return JSON.stringify(rows);
}
"""

let loginUi = "@js:_probeRows()"

// ⭐⭐⭐ **用 JSONEncoder 构造源 JSON**（别手拼 ⇒ 里面的换行/引号会炸）⭐⭐⭐
let sourceJSON: String = {
    let obj: [String: Any] = [
        "bookSourceUrl": "https://probe.invalid/login",
        "bookSourceName": "登录探针",
        "loginUi": loginUi,
        "jsLib": jsLib,
    ]
    let d = try! JSONSerialization.data(withJSONObject: obj, options: [])
    return String(data: d, encoding: .utf8)!
}()

// ── 跑柴阅的 resolveLoginRows ─────────────────────────────────────────────
let source = try! JSONDecoder().decode(BookSource.self, from: Data(sourceJSON.utf8))
let env = SourceEnvironment(store: MemoryKeyValueStore())
let web = WebBook(source: source, environment: env)

print("=== 登录表单探针（loginUi 是 @js: 薄壳）===")

let rows: [LoginRow]
do {
    rows = try await web.resolveLoginRows()
} catch {
    // ⚠️⚠️ **如实失败**（不伪装成功）⇒ CI（macOS）上这条会红 ⇒ 拦住「换装没解决」⭐⭐⭐
    print("FAIL: resolveLoginRows 抛错 ⇒ \(error)")
    exit(1)
}
print("ROWS=\(rows.count)")
for r in rows {
    print("  - name=\(r.name) type=\(r.type.rawValue) action=\(r.action ?? "")")
}

// ── 判定 ────────────────────────────────────────────────────────────────
let buttons = rows.filter { $0.type == .button }
if rows.isEmpty {
    print("FAIL: 柴阅也没解析出任何行 ⇒ 换装无效")
    exit(1)
}
if buttons.isEmpty {
    print("FAIL: 解析出行里没有 button ⇒ 登录面板还是没按钮")
    exit(1)
}
if !rows.contains(where: { $0.name == "密码" && $0.type == .password }) {
    print("FAIL: 缺 password 字段")
    exit(1)
}
print("OK")
