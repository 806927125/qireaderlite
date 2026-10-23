import Foundation
import LegadoCore

// ⭐⭐⭐ **新引擎（走 App 适配层）跑真实源** —— 跟老引擎做「真实源双实现对拍」
//
// ⚠️ 与 `test/old-engine-live.js` **步骤和输出格式必须完全一致** ⇒ 才能 diff
//   ① exploreKinds → ② explore → ③ bookInfo → ④ toc → ⑤ content
//
// 用法：new-engine-live <pack.json> [源名关键字]
// 输出：一行 JSON（与老引擎同格式）

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("{\"fatal\":\"用法: new-engine-live <pack.json> [源名关键字]\"}")
    exit(2)
}
let packPath = args[1]
let keyword = args.count >= 3 ? args[2] : ""
// ⭐⭐⭐ **指定要测哪本书**（两边跑**同一本书**才可比 ⇒ 列表顺序不同也没关系）
let wantBook = args.count >= 4 ? args[3] : ""

let data = try Data(contentsOf: URL(fileURLWithPath: packPath))
let pack = try JSONDecoder().decode([BookSource].self, from: data)
guard let src = pack.first(where: { $0.bookSourceName.contains(keyword) }) ?? pack.first else {
    print("{\"fatal\":\"没找到源\"}")
    exit(2)
}

/// 一小段 JSON 输出助手
func jsonString(_ s: String) -> String {
    // ⚠️ 必须返回**带引号的 JSON 文本**（直接 encode 字符串，别绕数组）
    return String(data: try! JSONEncoder().encode(s), encoding: .utf8)!
}
func step(_ name: String, _ fields: [(String, String)]) -> String {
    let body = fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",")
    return "\"\(name)\":{\(body)}"
}

var steps: [String] = []
var requestCount = 0

// ① 分类
do {
    let r = try LegadoEngineBackend.shared.invoke("exploreKinds", [:], source: src)
    let d = (r as? [String: Any]) ?? [:]
    let kinds = d["kinds"] as? [[String: Any]] ?? []
    let filters = d["filters"] as? [[String: Any]] ?? []
    steps.append(step("kinds", [("count", "\(kinds.count)"), ("filters", "\(filters.count)")]))
    let firstUrl = kinds.compactMap { $0["url"] as? String }.first { !$0.isEmpty } ?? ""

    if !firstUrl.isEmpty {
        // ② 发现
        do {
            let r2 = try LegadoEngineBackend.shared.invoke("explore", ["kindUrl": firstUrl, "page": 1], source: src)
            let d2 = (r2 as? [String: Any]) ?? [:]
            let books = d2["books"] as? [[String: Any]] ?? []
            // ⭐ 挑书：指定了就按名字找，没指定就第一本
            var picked: [String: Any]? = books.first
            if !wantBook.isEmpty {
                picked = books.first { ($0["name"] as? String) == wantBook }
            }
            let firstName = (picked?["name"] as? String) ?? ""
            steps.append(step("explore", [("count", "\(books.count)"), ("first", jsonString(firstName))]))

            if let b = picked, let bookUrl = b["bookUrl"] as? String, !bookUrl.isEmpty {
                // ③ 详情
                var bookDict: [String: Any] = b
                do {
                    let r3 = try LegadoEngineBackend.shared.invoke("bookInfo", ["bookUrl": bookUrl], source: src)
                    let d3 = (r3 as? [String: Any]) ?? [:]
                    let bi = (d3["book"] as? [String: Any]) ?? [:]
                    steps.append(step("bookInfo", [
                        ("name", jsonString((bi["name"] as? String) ?? "")),
                        ("author", jsonString((bi["author"] as? String) ?? "")),
                    ]))
                    bookDict = bi
                } catch {
                    steps.append(step("bookInfo", [("error", jsonString("\(error)"))]))
                }

                // ④ 目录
                var chapters: [[String: Any]] = []
                do {
                    let r4 = try LegadoEngineBackend.shared.invoke("toc", [
                        "tocUrl": (bookDict["tocUrl"] as? String) ?? "",
                        "bookUrl": bookUrl,
                        "book": bookDict,
                    ], source: src)
                    let d4 = (r4 as? [String: Any]) ?? [:]
                    chapters = d4["chapters"] as? [[String: Any]] ?? []
                    let firstTitle = (chapters.first?["title"] as? String) ?? ""
                    steps.append(step("toc", [("count", "\(chapters.count)"), ("first", jsonString(firstTitle))]))
                } catch {
                    steps.append(step("toc", [("error", jsonString("\(error)"))]))
                }

                // ⑤ 正文
                if let ch = chapters.first(where: { (($0["url"] as? String) ?? "").isEmpty == false && (($0["isVolume"] as? Bool) ?? false) == false }) {
                    do {
                        let r5 = try LegadoEngineBackend.shared.invoke("content", [
                            "chapterUrl": (ch["url"] as? String) ?? "",
                            "chapter": ch,
                            "book": bookDict,
                        ], source: src)
                        let d5 = (r5 as? [String: Any]) ?? [:]
                        let text = (d5["content"] as? String) ?? ""
                        steps.append(step("content", [("len", "\(text.count)")]))
                    } catch {
                        steps.append(step("content", [("error", jsonString("\(error)"))]))
                    }
                } else {
                    steps.append(step("content", [("error", jsonString("没有可用的章节"))]))
                }
            }
        } catch {
            steps.append(step("explore", [("error", jsonString("\(error)"))]))
        }
    } else {
        steps.append(step("explore", [("error", jsonString("没有分类 URL"))]))
    }
} catch {
    steps.append(step("kinds", [("error", jsonString("\(error)"))]))
}

let out = "{\"source\":\(jsonString(src.bookSourceName)),\"steps\":{\(steps.joined(separator: ","))}}"
print(out)
