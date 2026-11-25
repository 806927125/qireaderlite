import SwiftUI
import LegadoEngine
import ChaiyueReader

// ⭐⭐⭐⭐⭐ **宿主侧的柴阅「功能层」**（2026-11-25 接柴阅阅读器）⭐⭐⭐⭐⭐
//
// ⚠️⚠️⚠️ **为什么 shim 放在我们 App 侧（而不是包里）** ⭐⭐⭐：
//   柴阅自己的 `LibraryServices` 管着「书源仓 / 书架仓 / 替换规则 / 本地书 / 备份」，
//   而**轻阅的数据全在轻阅自己的 Store 里**（`SourceStore` / `LibraryStore`）
//   ⇒ 如果用柴阅的 `LibraryServices`，轻阅就变成「两套书库 + 两套书源」⇒ 用户看到的东西会打架 ⭐⭐⭐
//   ⇒ 所以：**包侧只留一个门面协议 `ChaiyueReaderLibrary`，实现放宿主** ⭐⭐⭐
//   ⇒ 阅读器（`ChaiyueReader`）只通过这个门面拿「书架 / 书源 / 会话」⇒ **不用改柴阅一行逻辑** ⭐⭐⭐
//
// ⚠️ **命名纪律** ⚠️：
//   本文件 `import ChaiyueReader` ⇒ 柴阅的 `Book` / `BookSource` 进了命名空间，
//   而宿主 App 侧**同名** ⇒ 所以：
//     · 柴阅的模型 ⇒ 一律写 `LegadoEngineHost.BookModel` / `.ChapterModel` / `.Source`（别名，唯一）⭐⭐⭐
//     · 宿主的模型 ⇒ 一律写 `QiBook` / `QiChapter` / `QiBookSource`（本地别名，唯一）⭐⭐⭐

// MARK: - 门面实现

/// ⭐⭐⭐⭐⭐ **宿主侧的书架 / 书源 / 会话仓** ⭐⭐⭐⭐⭐
///
/// 这就是任务书 B.2 说的「shim 放我们 App 侧」：
/// 柴阅的 `AppModel` 拿着它，阅读器要目录、要正文、要书签、要书源登录态，全都从这里来 ⭐⭐⭐
@MainActor
final class ChaiyueHostLibrary: ChaiyueReaderLibrary {

    /// 柴阅的书架仓：进度 / 书签 / 分组（阅读页的目录面板要读它）
    let shelf: BookshelfRepository
    /// 柴阅的书源仓：阅读页的「登录」按钮要在这儿查源（`source(for:)`）
    let sources: SourceRepository
    /// 在线朗读源：轻阅没有 ⇒ 空仓（阅读页的「朗读」面板会读它）
    let httpTTS: HttpTTSRepository
    /// 章节缓存（目录 + 正文）：轻阅复用柴阅的磁盘缓存 ⇒ 同一本书第二次打开**不重复下载** ⭐⭐⭐
    let chapterStore: ChapterStore
    /// 阅读记录：不在书架的书也记进度（下次打开接着读）
    let readingRecords: ReadingRecordStore

    /// 向后预缓存的章数（跟柴阅 `ReaderSettings.preloadCount` 同源）
    var preloadCount = 3
    /// 替换规则：轻阅没有替换规则仓 ⇒ 空（柴阅的 `ContentProcessor` 会原样处理正文）⭐⭐⭐
    var replaceRules: [ReplaceRule] = []

    init(directory: URL = AppPaths.chaiyueDir) {
        shelf = BookshelfRepository(fileURL: directory.appendingPathComponent("bookshelf.json"))
        sources = SourceRepository(fileURL: directory.appendingPathComponent("sources.json"))
        httpTTS = HttpTTSRepository(fileURL: directory.appendingPathComponent("httpTTS.json"))
        chapterStore = ChapterStore(root: directory.appendingPathComponent("Chapters", isDirectory: true))
        readingRecords = ReadingRecordStore(fileURL: directory.appendingPathComponent("readingRecords.json"))
    }

    // MARK: - 柴阅的阅读会话

    /// ⭐⭐⭐⭐⭐ **给这本书造一个柴阅的阅读会话** ⭐⭐⭐⭐⭐
    ///
    /// ⚠️ **这里就是柴阅 `LibraryServices.readerSession(for:)` 的等价实现**
    ///   （柴阅那份在 `Packages/ReaderCore/Sources/ReaderServices/LibraryServices.swift`）
    ///   —— 差别只有一个：**柴阅那份用它的 `LibraryServices` 造 service/processor，
    ///   我们这份用宿主自己的源与规则** ⇒ 行为一致，数据源不同 ⭐⭐⭐
    ///
    /// - Parameter book: **柴阅的书**（`ReaderContainer` 传进来的 `launch.book`）
    func readerSession(for book: LegadoEngineHost.BookModel) -> ReaderSession {
        // ① 正文服务：源（从柴阅的书源仓里取）+ 引擎环境（宿主与引擎共享的那一个）+ 章节缓存
        let source = sources.source(for: book.origin)
        let service = BookContentService(source: source,
                                         environment: ChaiyueRuntime.environment,
                                         store: chapterStore)
        // ② 正文处理器：替换规则 + 简繁转换（轻阅暂无替换规则 ⇒ 空；简繁转换走柴阅的 `ChineseConversion.none`）
        let processor = ContentProcessor(rules: replaceRules, conversion: .none)
        // ③ 会话
        let session = ReaderSession(book: book, shelf: shelf, service: service,
                                    processor: processor, preloadCount: preloadCount)
        session.readingRecords = readingRecords
        session.autoAddToShelf = { true }
        return session
    }

    /// 书源事件回调（`startRead` / `endRead` / 点击自定义按钮…）
    ///
    /// ⚠️ 柴阅里只有开了 `eventListener` 的源才会走到这里；
    ///   轻阅没有这条通道 ⇒ **只记一条日志**（不假装支持）⭐⭐⭐
    func callBack(_ event: SourceCallBackEvent, book: LegadoEngineHost.BookModel, chapter: LegadoEngineHost.ChapterModel?) {
        engineLog("[柴阅阅读器] 书源事件 \(event.rawValue) · 《\(book.name)》")
    }
}

// MARK: - 宿主

/// ⭐⭐⭐⭐⭐ **一次阅读会话的宿主对象** ⭐⭐⭐⭐⭐
///
/// 负责三件事：
///   ① 把轻阅的「书 / 目录 / 书源 / 书架进度」**镜像**进柴阅的仓（阅读器只认柴阅的仓）⭐⭐⭐
///   ② 造柴阅的 `AppModel`（= `ReaderContainer` 需要的 `@Environment(AppModel.self)`）⭐⭐⭐
///   ③ 退出时把进度**回写**回轻阅的书架（轻阅的书库才是主数据）⭐⭐⭐
@MainActor
final class ChaiyueReaderHost {

    /// 宿主侧的门面实现
    let library: ChaiyueHostLibrary
    /// 柴阅的 `AppModel`（阅读器的环境对象）
    let app: AppModel
    /// 柴阅的「打开阅读器」请求
    let launch: ReaderLaunch

    /// 轻阅侧的书（用于回写进度）
    private let qiBook: QiBook
    /// 轻阅侧的章表（用于回写章名）
    private let qiChapters: [QiChapter]

    init(book: QiBook,
         chapters: [QiChapter],
         start: QiChapter?,
         source: QiBookSource?,
         libraryItems: [LibraryItem],
         progressIndex: Int) {
        self.qiBook = book
        self.qiChapters = chapters
        self.library = ChaiyueHostLibrary()

        // ── ① 书源：轻阅的源 → 柴阅的源（写进柴阅的书源仓）─────────────
        //    ⚠️ 必须先写进去 ⇒ 阅读页的「登录」按钮（`sources.source(for:)`）才认得这个源 ⭐⭐⭐
        if let source, let converted = ChaiyueReaderAdapter.source(source) {
            library.sources.importSources([converted])
        }

        // ── ② 目录：轻阅的目录 → 柴阅的目录（预写进章节缓存）─────────────
        //    ⚠️ **为什么要预写**：柴阅的 `ReaderSession.open()` 会自己去取目录
        //      （`service.chapters(for:refresh:false)` ⇒ 缓存优先）
        //      ⇒ 轻阅详情页**已经取过一次**了 ⇒ 预写进缓存 ⇒ 阅读器直接命中缓存
        //      ⇒ **不重复请求站方**（省一次流量，也避免两次目录不一致）⭐⭐⭐
        let converted = ChaiyueReaderAdapter.chapters(chapters, bookUrl: book.cleanBookUrl)
        if !converted.all.isEmpty {
            library.chapterStore.saveChapters(converted.all, bookUrl: book.cleanBookUrl)
        }

        // ── ③ 起始章号 ────────────────────────────────────────────────
        //    ⚠️ 柴阅的 `durChapterIndex` 是**整表（含卷）的下标** ⭐⭐⭐
        //      ⇒ 我们传的 `start` 是「正文章」⇒ 要换算成整表下标 ⇒ 不能直接用 ✗⭐⭐⭐
        var startIndex = -1
        if let start {
            // 先在「正文章表」里找到它，再换算成整表下标
            let plainList = chapters.filter { !$0.isVolume }
            if let plainIndex = plainList.firstIndex(where: { $0.url == start.url }),
               let wholeIndex = converted.plainIndexes[safe: plainIndex] {
                startIndex = wholeIndex
            }
        }
        if startIndex < 0 { startIndex = progressIndex }

        // ── ④ 书：轻阅的书 → 柴阅的书（带上进度）──────────────────────
        let chaiyueBook = ChaiyueReaderAdapter.book(book, sourceName: source?.bookSourceName ?? book.sourceName,
                                                     chapterIndex: startIndex)
        chaiyueBook.totalChapterNum = chapters.filter { !$0.isVolume }.count
        if startIndex >= 0, startIndex < chapters.count {
            chaiyueBook.durChapterTitle = chapters[startIndex].title
        }

        // ── ⑤ 书架镜像：轻阅书库 → 柴阅书架仓（阅读器要读进度 / 书签）──
        //    ⚠️ 顺序很重要：**先铺书架，再放这一本** ⇒ 这一本带正确进度 ⭐⭐⭐
        for item in libraryItems {
            var mirrored = ChaiyueReaderAdapter.book(item.book, sourceName: item.book.sourceName,
                                                      chapterIndex: item.lastChapterIndex)
            mirrored.totalChapterNum = item.book.totalChapterNum
            library.shelf.add(mirrored)
        }
        library.shelf.add(chaiyueBook)

        // ── ⑥ 柴阅的 AppModel（阅读器的环境）────────────────────────────
        app = AppModel(library: library)
        // ⚠️ 用柴阅的 `openReader` 而不是自己造 `ReaderLaunch`：
        //   · 它会按**书架里的最新记录**取书（带进度）⇒ 不会丢掉「读到哪了」⭐⭐⭐
        //   · 它把 `app.reader` 置位 ⇒ 宿主靠 `app.reader == nil` 感知「阅读器被关掉了」
        //     （柴阅的 `ReaderContainer.close()` 调 `app.closeReader()` ⇒ 置 nil）⭐⭐⭐
        app.openReader(chaiyueBook)
        launch = app.reader ?? ReaderLaunch(book: chaiyueBook, origin: nil, coverKey: nil)
    }

    // MARK: - 回写

    /// ⭐⭐⭐ **退出阅读：把进度回写回轻阅的书架** ⭐⭐⭐
    ///
    /// ⚠️ 柴阅把进度写进了**它自己的**书架仓 ⇒ 轻阅的书库看不到 ⇒ 必须搬回来 ⭐⭐⭐
    /// - Returns: 读到的章下标（整表口径，-1 = 没读到）
    @discardableResult
    func writeBackProgress(to libraryStore: LibraryStore?) -> Int {
        guard let libraryStore else { return -1 }
        let stored = library.shelf.book(qiBook.cleanBookUrl)
        let index = stored?.durChapterIndex ?? -1
        guard index >= 0 else { return index }
        let title = stored?.durChapterTitle ?? qiChapters[safe: index]?.title ?? ""
        libraryStore.saveProgress(bookID: qiBook.id, chapterIndex: index, ratio: 0, chapterTitle: title)
        return index
    }
}

// MARK: - 小工具

extension Array {
    /// 安全下标（柴阅的目录是「整表（含卷）」，轻阅的章表口径不同 ⇒ 换算时越界很常见）⭐⭐⭐
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
