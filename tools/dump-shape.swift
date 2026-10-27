import Foundation
import LegadoCore

// 用**引擎自己的 RuleParser** 解析 UAA 原版的 chapterList（生产路径）
let fixture = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "test/fixtures/uaa-original.json"))) as! [[String: Any]]
let src = fixture[0]
let rule = (src["ruleToc"] as! [String: Any])["chapterList"] as! String

let parser = RuleParser()
let node = parser.parse(rule)
var code = ""
switch node {
case .js(let c): code = c
case .jsWithTail(let c, _): code = c
default: print("⚠️ 不是 JS 规则：\(node)"); exit(1)
}
print("解析后代码前 40 字：\(code.prefix(40).replacingOccurrences(of: "\n", with: "\\n"))")

let payload = "eyJ0eXBlIjoibm92ZWwiLCJub3ZlbElkIjoxMDA4OTQwOTI1NzcyMjM4ODQ4fQ=="
let baseUrl = "data:;base64,\(payload),{\"type\":\"novel\",\"novelId\":\"1008940925772238848\"}"
let ctx = JSRunContext(base: .page(payload), baseUrl: baseUrl, raw: payload)
let scope = JSScopeBuilder.build(ctx)

for (i, s) in JSEvalShape.scripts(for: code, scope: scope).enumerated() {
    try? s.write(toFile: "/tmp/s\(i + 1).js", atomically: true, encoding: .utf8)
    // ⭐ App 侧真正送进 WebView 的那段
    let wrapped = "JSON.stringify((0,eval)(" + JSEvalShape.jsonLiteral(s) + "))"
    try? wrapped.write(toFile: "/tmp/w\(i + 1).js", atomically: true, encoding: .utf8)
}
print("已写 /tmp/s{1,2,3}.js 与 /tmp/w{1,2,3}.js")
