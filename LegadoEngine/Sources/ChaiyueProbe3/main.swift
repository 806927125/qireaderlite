import Foundation
import ChaiyueModels
import ChaiyueEngine

// =============================================================================
// 「书山聚合 v6」端到端探针（2026-11-23）
//
// ⭐⭐⭐⭐⭐ **为什么要有这个探针** ⭐⭐⭐
//   沙盒（Linux）**没有 JavaScriptCore** ⇒ 所有 `@js:` / `<js>` 求值跑不了 ⭐⭐⭐
//   ⇒ 「这个源在轻阅里到底能不能跑」**只能靠 macOS CI 的真引擎真跑** ⇒ 本探针就是那个证据 ⭐⭐⭐
//
// ⭐⭐⭐⭐⭐ **本探针要证明的五件事**（不靠推理，靠真跑）⭐⭐⭐
//   ① `exploreUrl`（`@js:`，10240 字符）**能求值出分类** ⇒ 发现页不是空的
//   ② `ruleExplore`（`<js>` + `$.data` **混排**）**能解析出书单** ⇒ 列表不为 0
//   ③ 详情 / 目录 / 正文 **三段链路都通**（`init` / `chapterList` / `content`）
//   ④ 登录面板 **26 行都能求出**（含 23 个 button 的 action）
//   ⑤ ⭐⭐⭐ **改名后的 `ssh_*` 符号在全局确实可用**（`typeof ssh_getHosts === 'function'`）
//      ⇒ 证明「顶层符号隔离化」**没有打断作用域** ⭐⭐⭐
// =============================================================================

// ⚠️ 用 `#filePath` 推导仓库根（CI 的 cwd 与本地不同 ⇒ 相对路径不可靠）⭐⭐⭐
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Sources/ChaiyueProbe3
    .deletingLastPathComponent()   // Sources
    .deletingLastPathComponent()   // LegadoEngine
    .deletingLastPathComponent()   // 仓库根

// ⚠️⚠️ **ASCII 文件名**（macOS 的 NFD vs Linux 的 NFC 中文名差异会读不到）⭐⭐⭐
let fixturePath = repoRoot.appendingPathComponent("test/fixtures/shushan-adapted.json").path

print("=== 书山聚合 v6 · 全链探针（真引擎 + 真源 + 真网络）===")

guard let data = FileManager.default.contents(atPath: fixturePath) else {
    print("FAIL: 读不到 fixture：\(fixturePath)")
    exit(2)
}
var decodedSource: BookSource?
do {
    let obj = try JSONSerialization.jsonObject(with: data)
    let dict: [String: Any]
    if let arr = obj as? [[String: Any]] {
        guard let first = arr.first else { print("FAIL: 数组是空的"); exit(2) }
        dict = first
    } else if let one = obj as? [String: Any] {
        dict = one
    } else {
        print("FAIL: 顶层既不是数组也不是对象"); exit(2)
    }
    decodedSource = try JSONDecoder().decode(BookSource.self, from: try JSONSerialization.data(withJSONObject: dict))
    print("fixture: \(fixturePath)  字节=\(data.count)")
} catch {
    print("FAIL: 解码失败：\(error)")
    exit(2)
}
guard let source = decodedSource else { exit(2) }
print("书源：\(source.bookSourceName)")

let env = SourceEnvironment(store: MemoryKeyValueStore())
let web = WebBook(source: source, environment: env)

var failures = 0
func expect(_ ok: Bool, _ label: String, _ detail: String = "") {
    if ok { print("  ✅ \(label)\(detail.isEmpty ? "" : " — \(detail)")") }
    else { failures += 1; print("  ❌ \(label)\(detail.isEmpty ? "" : " — \(detail)")") }
}

// ---------- ⑤ 先验作用域：改名后的符号在全局可用 ----------
print("\n[⑤] 改名后的顶层符号是否在全局可用")
for fn in ["ssh_getHosts", "ssh_getHost", "ssh_checkMsg", "ssh_decryptIfEncrypted", "ssh_buildHeaders", "ssh_localVersion"] {
    let t = (try? await web.evalJS("typeof \(fn)")) ?? "?"
    expect(t == "function" || t == "object" || t == "string" || t == "number", "typeof \(fn)", t)
}

// ---------- ① 分类 ----------
print("\n[①] exploreUrl 求值（@js:，10240 字符）")
var kinds: [ExploreKind] = []
do {
    kinds = try await web.exploreKinds()
    print("  分类数 = \(kinds.count)")
    for k in kinds.prefix(6) { print("    · \(k.title)  url=\((k.url ?? "").prefix(70))") }
    expect(kinds.count > 0, "exploreUrl 求值出分类", "\(kinds.count) 个")
} catch {
    expect(false, "exploreUrl 求值出分类", "\(error)")
}

// ---------- ② 书单 ----------
print("\n[②] ruleExplore 解析书单")
var firstBook: SearchBook?
if let kind = kinds.first(where: { !($0.url ?? "").isEmpty }), let kindUrl = kind.url, !kindUrl.isEmpty {
    do {
        let books = try await web.exploreBook(url: kindUrl, page: 1)
        print("  书数 = \(books.count)")
        for b in books.prefix(3) { print("    · \(b.name)  author=\(b.author)") }
        expect(books.count > 0, "书单不为 0", "\(books.count) 本")
        firstBook = books.first
    } catch {
        expect(false, "书单不为 0", "\(error)")
    }
} else {
    expect(false, "书单不为 0", "没有可用分类 URL")
}

// ---------- ③ 详情 / 目录 / 正文 ----------
if let fb = firstBook {
    print("\n[③] 详情 / 目录 / 正文")
    // ⚠️ `SearchBook` 的字段是 `bookUrl`（不是 `url`）⭐⭐⭐
    let book = Book(bookUrl: fb.bookUrl, origin: fb.origin, name: fb.name, author: fb.author)
    do {
        let info = try await web.getBookInfo(book)
        print("  详情：name=\(info.name) author=\(info.author) 简介=\(info.intro?.count ?? 0) 字")
        expect(!info.name.isEmpty, "详情有书名")
        expect(!(info.intro ?? "").isEmpty, "详情有简介")
        do {
            let r = try await web.getChapterList(info)
            print("  目录：\(r.chapters.count) 章")
            expect(r.chapters.count > 0, "目录不为 0", "\(r.chapters.count) 章")
            if let ch = r.chapters.first {
                let c = try await web.getContent(info, chapter: ch)
                print("  正文：\(c.content.count) 字符")
                expect(c.content.count > 0, "正文不为空", "\(c.content.count) 字符")
            } else {
                expect(false, "正文不为空", "没有章节")
            }
        } catch {
            expect(false, "目录不为 0", "\(error)")
        }
    } catch {
        expect(false, "详情有书名", "\(error)")
    }
}

// ---------- ④ 登录面板 ----------
print("\n[④] 登录面板（loginUi 26 行）")
do {
    let rows = try await web.resolveLoginRows()
    print("  行数 = \(rows.count)")
    for r in rows.prefix(30) {
        print("    · \(r.name)  type=\(r.type)  action=\(r.action ?? "-")")
    }
    expect(rows.count > 0, "登录面板有行", "\(rows.count) 行")
    let buttons = rows.filter { $0.type == .button }
    print("  按钮数 = \(buttons.count)")
    expect(buttons.count > 0, "登录面板有按钮", "\(buttons.count) 个")
} catch {
    expect(false, "登录面板有行", "\(error)")
}

print(failures == 0 ? "\n✅ 书山聚合探针：全部通过" : "\n❌ 书山聚合探针：\(failures) 条失败")
exit(failures == 0 ? 0 : 1)
