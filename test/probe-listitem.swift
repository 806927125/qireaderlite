import Foundation
import LegadoCore

// ⭐⭐ 探针：**列表项（ListItem）到底长啥样** —— 纯 Swift 沙盒可跑（不需要 JSC）
//
// 背景：大灰狼的 `ruleExplore.bookUrl` 是 `<js>` 规则，要拿 `result.book_id`
//   ⇒ 真机上 bookUrl **空** ⇒ 说明 JS 里的 `result` 拿不到列表项
//   ⇒ ⇒ 用假源验证「列表项 → base → result」这一环
//
// 假源：
//   exploreUrl = 静态 URL（不跑 JS）
//   bookList   = `$.data`      （JSONPath ⇒ 列表项是 JSON 对象）
//   bookUrl    = `<js>…</js>`  （沙盒没 JSC ⇒ 跑不了 ⇒ 正是要验的那一环）

final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private let byURL: [String: String]
    init(_ byURL: [String: String]) { self.byURL = byURL }
    func send(_ request: HTTPRequest) throws -> HTTPResponse {
        guard let body = byURL[request.url] else {
            throw SourceError.requestFailed(request.url, "假传输里没有这个 URL")
        }
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8), finalURL: request.url)
    }
}

let listJSON = """
{"code":0,"data":[
  {"book_id":"7414308239","book_name":"麻衣风水师","source":"番茄","tab":"小说","toc_url":"","author":"梭罗果"},
  {"book_id":"998877","book_name":"第二本","source":"七猫","tab":"小说","toc_url":"","author":"某人"}
]}
"""

let sourceJSON = """
{"bookSourceName":"假源","bookSourceUrl":"https://fake.example.com",
 "exploreUrl":"玄幻::https://fake.example.com/list",
 "ruleExplore":{"bookList":"$.data","name":"book_name","author":"author",
                "bookUrl":"<js>\\nlet id = result.book_id;\\n`data:;base64,${id}`\\n</js>"}}
"""

let source = try JSONDecoder().decode(LegadoCore.BookSource.self, from: Data(sourceJSON.utf8))
let transport = FakeTransport(["https://fake.example.com/list": listJSON])
let engine = SourceEngine(source: source, fetcher: PageFetcher(transport: transport))

print("\n=== ② 列表规则求值（走编排层的 books()）===")
let books = try engine.explore("https://fake.example.com/list")
for b in books {
    print("  name=\(b.name) | raw.book_id=\(b.raw["book_id"] ?? "（无）") | bookUrl=（沙盒无 JSC ⇒ `<js>` 求不了）")
    print("     raw 字段 = \(b.raw.keys.sorted().joined(separator: ", "))")
}
