import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LegadoCore

// ============================================================
// ⭐⭐⭐⭐⭐ **「解锁态 ⇒ 分类能出来」这条链的门禁**（2026-11-10 真机实证）
//
// ── 真机症状 ──────────────────────────────────────────────────────
//   发现页只有 1 个分类 ⇒ App 判「exploreKinds 结果不可信」⇒ 整页空
//
// ── 根因（App 侧，本门禁钉住的就是它）────────────────────────────
//   引擎里有**两个**变量盒子：
//     · `varBox`   = 规则/模板读写的源级变量
//     · `javaVars` = `java.get/put` 用的那个
//   而站方聚合源的 `exploreUrl` 首句是 `if (!nhAuth()) { return ""; }`
//   `nhAuth()` 读 `source.get("nhAuthed")`（解锁态）
//   ⇒ **解锁态必须能被新引擎读到**，否则永远「未解锁」⇒ 交白卷 ⇒ 兜底分类 ⭐⭐⭐
//
//   ⇒ 轻阅以前**只灌 `varBox`** ⇒ `javaVars` 永远是空的 ⭐⭐⭐
//   ⇒ 修法：**灌两个盒子 + 导出两个盒子**（`seedVars(..., and:)` / `varsJSON(..., and:)`）
//
// ⚠️ **为什么这里是【纯本地】断言**：
//   站方 exploreUrl 的 JS 需要**带方法的 `source`**（`source.get/put`）
//   ⇒ Node 后端的 `source` 是拍平对象 ⇒ 跑不出真分类（那是 harness 的活）
//   ⇒ 本门禁只钉【轻阅自己的那两行**：变量要进两个盒子、也要从两个盒子出来 ⭐⭐⭐
//   ⇒ 真网络那一半在 `test/explore-network-e2e.test.js`（老引擎 harness）⭐⭐⭐
// ============================================================

var pass = 0, fail = 0
func ok(_ c: Bool, _ m: String, _ extra: String = "") {
    if c { pass += 1; print("  ✓ " + m) }
    else { fail += 1; print("  ✗ " + m + (extra.isEmpty ? "" : "  → " + extra)) }
}

let srcPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/workspace/out/NovelHub聚合小说-轻阅版.json"

guard let data = FileManager.default.contents(atPath: srcPath),
      let parsed = try? JSONSerialization.jsonObject(with: data) else {
    print("❌ 读不到源文件：\(srcPath)"); exit(2)
}
var obj: [String: Any]
if let arr = parsed as? [[String: Any]], let f = arr.first { obj = f }
else if let one = parsed as? [String: Any] { obj = one }
else { print("❌ 源文件形状不对"); exit(2) }

let jsLib = obj["jsLib"] as? String ?? ""
let srcData = try! JSONSerialization.data(withJSONObject: obj)
let src = try! JSONDecoder().decode(LegadoCore.BookSource.self, from: srcData)
print("=== 源：\(obj["bookSourceName"] ?? "?") ===")

// ── ① 站方确实有「解锁门禁」⇒ 这条断言才有意义 ────────────────────
print("\n=== ① 站方的解锁门禁（前提）===")
ok(jsLib.contains("function nhAuth"), "⭐⭐⭐ 站方 jsLib 里有 nhAuth()（解锁门禁）")
ok((obj["exploreUrl"] as? String ?? "").contains("nhAuth()"),
   "⭐⭐⭐ 站方 exploreUrl 的首句就是 nhAuth()（未解锁 ⇒ 交白卷）")

// ── ② 轻阅必须把变量灌进【两个盒子】 ──────────────────────────────
print("\n=== ② 灌变量：两个盒子都要有（本次修复点）===")
let js = try! NodeJSExecutor()
let engine = SourceEngine(source: src,
                          fetcher: PageFetcher(transport: URLSessionTransport()),
                          js: js)
if !jsLib.isEmpty { try! engine.loadJsLib(jsLib) }

let payload: [String: Any] = [
    "source": ["__variables": #"{"nhAuthed":"0c220581ebbb1121d9c2b33466045387","aid":"42"}"#]
]
LegadoEngineBackend.seedVars(from: payload, into: engine.varBox, and: engine.javaVars)

ok(engine.varBox.get("nhAuthed") == "0c220581ebbb1121d9c2b33466045387",
   "⭐⭐⭐ varBox 里有 nhAuthed（规则/模板读的那套）")
ok(engine.javaVars.get("nhAuthed") == "0c220581ebbb1121d9c2b33466045387",
   "⭐⭐⭐⭐⭐ javaVars 里有 nhAuthed（站方 source.get()/java.get() 读的那套）",
   "实际：\(engine.javaVars.get("nhAuthed") ?? "(空)")")
ok(engine.javaVars.get("aid") == "42", "⭐⭐⭐ javaVars 里连普通变量也有")

// ── ③ 引擎的 sourceObject 必须能读到解锁态 ────────────────────────
print("\n=== ③ 站方 source.get() 必须读得到解锁态 ===")
let got = engine.sourceObject?.call("get", [.string("nhAuthed")])?.scalarString ?? ""
ok(got == "0c220581ebbb1121d9c2b33466045387",
   "⭐⭐⭐⭐⭐ sourceObject.get('nhAuthed') = 解锁态（站方 nhAuth() 的输入）", "实际：\(got)")

// ── ④ 落盘必须导出【两个盒子】 ───────────────────────────────────
print("\n=== ④ 落盘：两个盒子都要导出（本次修复点）===")
engine.javaVars.set("onlyInJavaBox", "V1")
let out = LegadoEngineBackend.varsJSON(engine.varBox, and: engine.javaVars)
let parsedOut = (try? JSONSerialization.jsonObject(with: out.data(using: .utf8)!)) as? [String: Any] ?? [:]
ok(parsedOut["nhAuthed"] as? String == "0c220581ebbb1121d9c2b33466045387",
   "⭐⭐⭐ 导出的 JSON 里有 nhAuthed（解锁态能落盘 ⇒ 下次启动仍然有效）")
ok(parsedOut["onlyInJavaBox"] as? String == "V1",
   "⭐⭐⭐⭐⭐ javaVars 独有的项也导出了（只导 varBox ⇒ 站方写的东西全丢）")
ok(parsedOut["aid"] as? String == "42", "⭐⭐⭐ varBox 的项也在")

print("\n\(fail == 0 ? "✅" : "❌") 通过 \(pass) / 失败 \(fail)")
exit(fail == 0 ? 0 : 1)
