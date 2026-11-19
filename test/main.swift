import Foundation

// ⚠️ 入口：读 fixture ⇒ 跑 App 真文件的归一化 ⇒ 打印 JSON
//   （与 test/explore-kinds-parity.js 里的入口同款 ⇒ 语义一致）
let path = CommandLine.arguments[1]
let data = FileManager.default.contents(atPath: path)!
let fixture = try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
var results: [[String: Any]] = []
for f in fixture {
    let name = f["name"] as! String
    let base = f["base"] as! String
    let input = f["input"]!
    let norm = ExploreKindsNormalizer.normalizeKinds(input, baseUrl: base)
    results.append([
        "name": name,
        "kinds": norm.kinds.map { k -> [String: Any] in
            var o: [String: Any] = [:]
            for key in ["title", "url", "style", "group"] { o[key] = k[key] ?? "" }
            return o
        },
        "filters": norm.filters.map { f -> [String: Any] in
            var o: [String: Any] = [:]
            for key in ["title", "type", "chars", "default", "paramKey", "action"] { o[key] = f[key] ?? "" }
            return o
        },
    ])
}
let out = try! JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(out)
