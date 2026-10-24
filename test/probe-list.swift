import Foundation
import LegadoCore

// ⭐ 探针：新引擎的**列表项**长什么样（沙盒可跑 ⇒ 因为 bookList 是 `$.data`，不需要 JS）
// 用法：probe-list <pack.json> [源名关键字]
let packPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
    : "/workspace/qireaderlite/sources/🍅大灰狼聚合5.9.30-轻阅适配版v2.json"
let keyword = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
let pack = try JSONDecoder().decode([BookSource].self, from: try Data(contentsOf: URL(fileURLWithPath: packPath)))
guard let src = pack.first(where: { $0.bookSourceName.contains(keyword) }) ?? pack.first else {
    print("没找到源"); exit(2)
}
print("源 = \(src.bookSourceName)")

// ① 分类
let r1 = try LegadoEngineBackend.shared.invoke("exploreKinds", [:], source: src)
let d1 = (r1 as? [String: Any]) ?? [:]
let kinds = d1["kinds"] as? [[String: Any]] ?? []
print("分类数 = \(kinds.count)")
let usable = kinds.compactMap { $0["url"] as? String }.filter { !$0.isEmpty && !$0.hasPrefix("{{") }
print("可用分类 URL 数 = \(usable.count)")
guard let kindUrl = usable.first else { print("没有可用分类"); exit(1) }
print("用分类 = \(kindUrl.prefix(90))")

// ② 发现
let r2 = try LegadoEngineBackend.shared.invoke("explore", ["kindUrl": kindUrl, "page": 1], source: src)
let d2 = (r2 as? [String: Any]) ?? [:]
let books = d2["books"] as? [[String: Any]] ?? []
print("书数 = \(books.count)")
for (i, b) in books.prefix(3).enumerated() {
    print("  第\(i+1)本: name=\(b["name"] ?? "?")")
    print("     bookUrl = \(String(describing: b["bookUrl"] ?? "").prefix(100))")
    let raw = b["raw"] as? [String: String] ?? [:]
    print("     raw 字段 = \(raw.keys.sorted().joined(separator: ", "))")
    if let bid = raw["book_id"] { print("     raw.book_id = \(bid)") }
}
