import Foundation
import LegadoEngine

// ⚠️⚠️⚠️ **本文件【故意不 import ChaiyueReader】** ⭐⭐⭐：
//   `import ChaiyueReader` 会把柴阅的 `Book` / `BookSource` 一起带进来，
//   而宿主 App 侧**同名**（`Core/Book.swift`）⇒ 两个模块都有 ⇒ 裸写类型名就可能「ambiguous」⭐⭐⭐
//   ⇒ 所以：**需要柴阅类型的地方一律用 `LegadoEngineHost.*` 别名**（`LegadoEngine` 模块再导出一次）
//     ⇒ 需要引用**我们自己的** `Book` / `Chapter` / `BookSource` 的文件（要 import ChaiyueReader 的那些）
//     ⇒ 用下面这三个别名（定义在本文件 ⇒ 本文件不 import ChaiyueReader ⇒ 解析到的一定是宿主自己的）⭐⭐⭐

/// 宿主自己的书（`Core/Book.swift`）
typealias QiBook = Book
/// 宿主自己的章（`Core/Book.swift`）
typealias QiChapter = Chapter
/// 宿主自己的书源（`Core/BookSource.swift`）
typealias QiBookSource = BookSource

// ⭐⭐⭐⭐⭐ **轻阅 → 柴阅 的模型适配层**（2026-11-25 接柴阅阅读器）⭐⭐⭐⭐⭐
//
// ⚠️⚠️⚠️ **为什么必须有这一层** ⭐⭐⭐：
//   轻阅的模型（`Core/Book.swift`）与柴阅的模型（`ChaiyueModels`）**同源但不是同一个类型**：
//     · 我们的 `Book`       ⇒ 柴阅 `ChaiyueModels.Book`
//     · 我们的 `Chapter`    ⇒ 柴阅 `ChaiyueModels.BookChapter`
//     · 我们的 `BookSource` ⇒ 柴阅 `ChaiyueModels.BookSource`
//   ⇒ 老阅读器（`Features/Reader/Paging/` 那一整套 + WebView 阅读页）是**自己排版、自己拉正文**的，
//     所以它只认我们自己的模型；
//   ⇒ 柴阅阅读器（`ChaiyueReader`）走的是柴阅的权威链路：
//       `BookContentService` → `ContentProcessor` → `ReaderSession` → `ReaderModel` → `ReaderKit` 排版
//     ⇒ **必须把我们的模型翻译成柴阅的模型**，否则接不上 ⭐⭐⭐
//
// ⭐⭐⭐ **命名纪律（血坑预防）** ⭐⭐⭐：
//   轻阅 App 侧已经有 `Book` / `Chapter` / `BookSource` 三个类型，
//   而 `import ChaiyueReader` 会把柴阅的**同名类型**也带进来（`@_exported import`）
//   ⇒ 两个模块都导出 `Book` ⇒ **裸写 `Book` 会「ambiguous for type lookup」编译错** ⭐⭐⭐
//   ⇒ 所以这里**一律用 `LegadoEngineHost.*` 这组别名**（`LegadoEngine` 模块把柴阅模型再导出了一次）
//     ⇒ 名字唯一 ⇒ 永远不会撞 ⭐⭐⭐
enum ChaiyueReaderAdapter {

    // MARK: - 书籍

    /// ⭐⭐⭐ **我们的书 → 柴阅的书** ⭐⭐⭐
    ///
    /// ⚠️ **`bookUrl` 必须用 `cleanBookUrl`**（规范化过）：
    ///   柴阅的 `Book.id` 就是 `bookUrl`，而章��缓存（`ChapterStore`）也是按 `bookUrl` 分目录的
    ///   ⇒ 详情页拿到的原始 URL 与规范化后的 URL 不一致 ⇒ 缓存会分叉 ⇒ 每章都重新下载 ⭐⭐⭐
    ///
    /// - Parameters:
    ///   - b: 轻阅的书
    ///   - sourceName: 书源名（我们的 `Book.sourceName` 常常是空的 ⇒ 用源仓里的名字兜底）
    ///   - chapterIndex: 起始章号（-1 = 不知道 ⇒ 用 0）
    static func book(_ b: Book, sourceName: String = "", chapterIndex: Int = -1) -> LegadoEngineHost.BookModel {
        var book = LegadoEngineHost.BookModel()
        book.bookUrl = b.cleanBookUrl.isEmpty ? b.bookUrl : b.cleanBookUrl
        book.origin = b.origin
        book.originName = sourceName.isEmpty ? b.sourceName : sourceName
        book.name = b.name
        book.author = b.author
        book.kind = empty(b.kind)
        book.intro = empty(b.intro)
        book.coverUrl = empty(b.cleanCover)
        book.tocUrl = b.tocUrl
        book.wordCount = empty(b.wordCount)
        book.latestChapterTitle = empty(b.lastChapter)
        if chapterIndex >= 0 {
            book.durChapterIndex = chapterIndex
        }
        return book
    }

    /// ⭐⭐⭐ **我们的章 → 柴阅的章** ⭐⭐⭐
    ///
    /// ⚠️ **`index` 必须是「全书连续序号」**（含卷）—— 柴阅的 `ReaderSession` 用它当数组下标
    ///   ⇒ 我们的 `Chapter.index` 来自目录解析（**可能带卷**）⇒ 直接搬会错位 ⇒
    ///   ⇒ 这里**重排一遍**：按顺序给每一章（含卷）编号 ⭐⭐⭐
    static func chapter(_ c: Chapter, index: Int, bookUrl: String) -> LegadoEngineHost.ChapterModel {
        var chapter = LegadoEngineHost.ChapterModel()
        chapter.url = c.url
        chapter.title = c.title
        chapter.index = index
        chapter.isVolume = c.isVolume
        chapter.isVip = c.isVip
        chapter.isPay = c.isPay
        chapter.tag = empty(c.tag)
        chapter.bookUrl = bookUrl
        return chapter
    }

    /// ⚠️ **柴阅的 `nilIfEmpty` 是 internal** ⇒ 宿主看不到 ⇒ 这里自己写一个 ⭐⭐⭐
    private static func empty(_ s: String) -> String? {
        s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
    }

    /// ⭐⭐⭐ **我们的整张目录 → 柴阅的目录** ⭐⭐⭐
    ///
    /// ⚠️⚠️ **章号必须连续且从 0 开始**（含卷章）⭐⭐⭐：
    ///   柴阅的 `ReaderSession.chapters` 是**数组**，`position.chapterIndex` 是**下标**
    ///   ⇒ 我们的 `BookCatalog.plain`（过滤掉卷）**不能直接用** ⇒ 会整体错位 ⭐⭐⭐
    ///
    /// - Returns: (整表, 正文章下标表) —— 后者给出「正文章」在整表里的下标
    static func chapters(_ list: [Chapter], bookUrl: String) -> (all: [LegadoEngineHost.ChapterModel], plainIndexes: [Int]) {
        var all: [LegadoEngineHost.ChapterModel] = []
        var plainIndexes: [Int] = []
        for (i, c) in list.enumerated() {
            all.append(chapter(c, index: i, bookUrl: bookUrl))
            if !c.isVolume { plainIndexes.append(i) }
        }
        return (all, plainIndexes)
    }

    // MARK: - 书源

    /// ⭐⭐⭐⭐⭐ **我们的书源 → 柴阅的书源** ⭐⭐⭐⭐⭐
    ///
    /// ⚠️⚠️⚠️ **必须复用引擎那套 JSON 往返，别自己写字段映射** ⭐⭐⭐：
    ///   轻阅的 `BookSource` 与柴阅的 `BookSource` **字段名一一对应**（都是 Legado 语义）
    ///   ⇒ 用 `JSONEncoder` / `JSONDecoder` 往返一次就是**逐字一致**的转换 ⭐⭐⭐
    ///   ⇒ 而手写映射 = 几十个字段 = 漏一个字段就少一条规则 ⇒ 站方行为跟柴阅不一致 ⇒ **不能这么干** ⭐⭐⭐
    ///   ⇒ 引擎侧 `LegadoEngineBackend.parseSource` 用的就是这个往返 ⇒ **同一个语义** ⭐⭐⭐
    ///
    /// ⚠️ **必须先剥掉 `__` 前缀的内部键**（`__variables` / `__variable` / `__loginInfo` …）：
    ///   那是宿主注入引擎的内部通道，柴阅的模型不认识 ⇒ 解码会失败 ⭐⭐⭐
    static func source(_ s: BookSource) -> LegadoEngineHost.Source? {
        // ① 走宿主模型自身的 JSON（源仓里已用 `SourceRawArchive` 补过 loginUi / jsLib）
        if let data = try? AppEncoder.encode(s),
           let parsed = try? JSONDecoder().decode(LegadoEngineHost.Source.self, from: data) {
            return parsed
        }
        // ② 兜底：直接从原始 JSON 存档解（宿主模型的某些字段可能编不回去）
        if let raw = SourceRawArchive.raw(for: s.bookSourceUrl) {
            var clean: [String: Any] = [:]
            for (k, v) in raw where !k.hasPrefix("__") { clean[k] = v }
            if JSONSerialization.isValidJSONObject(clean),
               let data = try? JSONSerialization.data(withJSONObject: clean),
               let parsed = try? JSONDecoder().decode(LegadoEngineHost.Source.self, from: data) {
                return parsed
            }
        }
        return nil
    }
}
