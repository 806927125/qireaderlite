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
    /// 朗读音频加载器（柴阅的 `SpeechAudioLoader`）⭐⭐⭐
    let speechLoader: SpeechAudioLoader
    /// 章节缓存（目录 + 正文）：轻阅复用柴阅的磁盘缓存 ⇒ 同一本书第二次打开**不重复下载** ⭐⭐⭐
    let chapterStore: ChapterStore
    /// 阅读记录：不在书架的书也记进度（下次打开接着读）
    let readingRecords: ReadingRecordStore
    /// ⭐⭐⭐ **图片缓存（封面 / 正文插图）**：与柴阅 `LibraryServices.images` 同构 ⭐⭐⭐
    /// （柴阅原版：`ImageCache(directory:environment:)`，放在 `Images` 目录下）⭐⭐⭐
    private let images: ImageCache

    /// 向后预缓存的章数（跟柴阅 `ReaderSettings.preloadCount` 同源）
    var preloadCount = 3
    /// 替换规则：轻阅没有替换规则仓 ⇒ 空（柴阅的 `ContentProcessor` 会原样处理正文）⭐⭐⭐
    var replaceRules: [ReplaceRule] = []

    /// ⭐⭐⭐⭐⭐ **会话缓存：一本书一个会话** ⭐⭐⭐⭐⭐
    ///
    /// ⚠️⚠️⚠️ **为什么必须缓存**（不然进度会分叉）⭐⭐⭐：
    ///   柴阅的 `ReaderContainer` 启动时会调 `app.library.readerSession(for: launch.book)`
    ///   ⇒ 宿主侧如果每次都**新建**一个会话 ⇒ 界面用的会话与宿主手里的是**两个对象**
    ///   ⇒ 界面里翻到的位置写在 A 会话上，宿主回写进度时读的是 B 会话 ⇒ **进度永远是 0** ⭐⭐⭐
    ///   ⇒ 所以：**同一本书永远返回同一个会话** ⭐⭐⭐
    private var sessions: [String: ReaderSession] = [:]
    /// ⭐⭐⭐ **漫画会话缓存**（2026-11-26 · 漫画阅读器）⭐⭐⭐
    ///   与 `sessions` 同理：同一本书 ⇒ 同一个会话 ⇒ 漫画页与宿主共享进度 ⭐⭐⭐
    private var mediaSessions: [String: MediaSession] = [:]

    init(directory: URL = AppPaths.chaiyueDir) {
        shelf = BookshelfRepository(fileURL: directory.appendingPathComponent("bookshelf.json"))
        sources = SourceRepository(fileURL: directory.appendingPathComponent("sources.json"))
        httpTTS = HttpTTSRepository(fileURL: directory.appendingPathComponent("httpTTS.json"))
        speechLoader = SpeechAudioLoader(environment: ChaiyueRuntime.environment)
        chapterStore = ChapterStore(root: directory.appendingPathComponent("Chapters", isDirectory: true))
        readingRecords = ReadingRecordStore(fileURL: directory.appendingPathComponent("readingRecords.json"))
        images = ImageCache(directory: directory.appendingPathComponent("Images", isDirectory: true),
                            environment: ChaiyueRuntime.environment)
    }

    // MARK: - 图片（封面 / 正文插图）

    /// ⭐⭐⭐⭐⭐ **图片数据：走书源的请求头 + 解密脚本** ⭐⭐⭐⭐⭐
    ///
    /// ⚠️ **这就是柴阅 `LibraryServices.imageData(_:for:)` 的等价实现**：
    ///   柴阅那份在 `Packages/ReaderCore/Sources/ReaderServices/LibraryServices.swift`：
    ///   ```swift
    ///   public func imageData(_ url: String, for book: Book? = nil) async throws -> Data {
    ///       if LocalBookStore.handles(url) { …本地书… }
    ///       return try await images.data(for: url, source: book.flatMap(source(for:)))
    ///   }
    ///   ```
    ///   轻阅没有本地书（`LocalBookStore.handles` 恒 false）⇒ 只剩网络书那一支 ⭐⭐⭐
    ///   ⇒ **行为一致，数据源不同**：柴阅用它自己的书源仓，轻阅用自己的 `sources` ⭐⭐⭐
    func imageData(_ url: String, for book: LegadoEngineHost.BookModel?) async throws -> Data {
        let source = book.flatMap { sources.source(for: $0.origin) }
        return try await images.data(for: url, source: source)
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
        // ⭐⭐⭐ 同一本书 ⇒ 同一个会话（否则界面与宿主的进度会分叉）⭐⭐⭐
        if let existing = sessions[book.bookUrl] { return existing }
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
        sessions[book.bookUrl] = session
        return session
    }

    /// ⭐⭐⭐⭐⭐ **给这本书造一个【漫画会话】**（2026-11-26 · 漫画阅读器）⭐⭐⭐⭐⭐
    ///
    /// ⚠️ **柴阅的 `ComicReaderScreen` 就是这么拿数据的**：
    ///   `ComicModel(session: app.library.mediaSession(for: launch.book))` ⇒
    ///   **这个成员缺了 ⇒ 漫画阅读器连编都编不过** ⭐⭐⭐
    ///
    /// ⚠️ **与 `readerSession(for:)` 的差别只有一个**：会话类型不同（`MediaSession` vs `ReaderSession`）
    ///   ⇒ service / processor / shelf 全部复用 ⇒ **正文与目录走同一条链**（不重复请求站方）⭐⭐⭐
    func mediaSession(for book: LegadoEngineHost.BookModel) -> MediaSession {
        // ⭐⭐⭐ 同一本书 ⇒ 同一个会话（漫画页与宿主共享进度 ⇒ 不分叉）⭐⭐⭐
        if let existing = mediaSessions[book.bookUrl] { return existing }
        let source = sources.source(for: book.origin)
        let service = BookContentService(source: source,
                                         environment: ChaiyueRuntime.environment,
                                         store: chapterStore)
        let processor = ContentProcessor(rules: replaceRules, conversion: .none)
        let session = MediaSession(book: book, shelf: shelf, service: service, processor: processor)
        session.readingRecords = readingRecords
        session.autoAddToShelf = { true }
        mediaSessions[book.bookUrl] = session
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
    /// 柴阅的「打开阅读器」请求（**漫画模式没有它** ⇒ optional）⭐⭐⭐
    let launch: ReaderLaunch?
    /// ⭐⭐⭐⭐⭐ **这次开的是文字阅读器还是漫画阅读器**（2026-11-26 · 漫画阅读器）⭐⭐⭐⭐⭐
    ///   柴阅的两种页面走不同的 launch：文字走 `app.reader`、漫画走 `app.media` ⇒ 不能混 ⭐⭐⭐
    enum Mode {
        case text
        case comic
    }
    let mode: Mode
    /// 柴阅的书（漫画的 `MediaLaunch` 也要用它）
    let chaiyueBook: LegadoEngineHost.BookModel
    /// ⭐⭐⭐ **柴阅的阅读会话**（界面与宿主共用这一份 ⇒ 进度不分叉）⭐⭐⭐
    let session: ReaderSession
    // ⭐⭐⭐ **不再单独持 `ReaderModel`**（2026-11-26 · CI28 实证）⭐⭐⭐
    //   柴阅的 `ReaderModel` 是**包内 internal 类型** ⇒ 宿主看不见 ⇒ 报
    //   `cannot find type 'ReaderModel' in scope` ⭐⭐⭐
    //   ⇒ 而宿主要它只是为了读「当前读到第几章」⇒ **柴阅的 `ReaderModel` 每次翻页都会
    //     `session.updatePosition(...)`** ⇒ **直接读 `session.position` 就是实时的** ⭐⭐⭐
    //   ⇒ 少一个跨模块类型、少一份状态 ⇒ 更稳 ⭐⭐⭐

    /// 轻阅侧的书（用于回写进度）
    private let qiBook: QiBook
    /// 轻阅侧的章表（用于回写章名）
    private let qiChapters: [QiChapter]
    /// ⭐⭐⭐ **正章节下标 → 整表下标**（轻阅口径 → 柴阅口径）⭐⭐⭐
    private let plainToWhole: [Int]
    /// ⭐⭐⭐ **整表下标 → 正章节下标**（柴阅口径 → 轻阅口径）⭐⭐⭐
    private let wholeToPlain: [Int: Int]

    init(book: QiBook,
         chapters: [QiChapter],
         start: QiChapter?,
         source: QiBookSource?,
         libraryItems: [LibraryItem],
         progressIndex: Int,
         mode: Mode = .text) {
        self.mode = mode
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
        // ⭐⭐⭐ 两套下标口径的换算表（轻阅正章节 ↔ 柴阅整表）⭐⭐⭐
        plainToWhole = converted.plainIndexes
        var inverse: [Int: Int] = [:]
        for (plain, whole) in converted.plainIndexes.enumerated() { inverse[whole] = plain }
        wholeToPlain = inverse

        // ── ③ 书架镜像：轻阅书库 → 柴阅书架仓（阅读器要读进度 / 书签）──
        //    ⚠️⚠️ **已存在的条目不许覆盖它的进度** ⭐⭐⭐：
        //      柴阅阅读时把进度写进**柴阅的**书架仓 ⇒ 万一 App 被杀（没回写）
        //      ⇒ 柴阅那份更新、App 那份旧 ⇒ 这次镜像若用 App 的旧值覆盖 ⇒ **用户的阅读位置丢了** ⭐⭐⭐
        //      ⇒ 所以：**书架仓里已有的进度优先** ⇒ 只有新书才用轻阅的进度播种 ⭐⭐⭐
        for item in libraryItems {
            // ⚠️ 轻阅的 `lastChapterIndex` 是**正章节下标** ⇒ 换算成柴阅的整表下标 ⭐⭐⭐
            let whole = plainToWhole[safe: item.lastChapterIndex] ?? item.lastChapterIndex
            var mirrored = ChaiyueReaderAdapter.book(item.book, sourceName: item.book.sourceName,
                                                      chapterIndex: whole)
            // ⚠️ **轻阅的 `Book` 模型没有「总章节数」字段**（CI28：`has no member 'totalChapterNum'`）
            //   ⇒ 柴阅的 `totalChapterNum` 留 0 ⇒ 柴阅自己拉完目录会填 ⭐⭐⭐
            if let stored = library.shelf.book(mirrored.bookUrl) {
                // ⚠️ 保留书架仓里的进度（可能是上次没写回 App 的新进度）⭐⭐⭐
                mirrored.durChapterIndex = stored.durChapterIndex
                mirrored.durChapterPos = stored.durChapterPos
                mirrored.durChapterTitle = stored.durChapterTitle
            }
            library.shelf.add(mirrored)
        }

        // ── ④ 起始章号 ────────────────────────────────────────────────
        //    ⚠️ 柴阅的 `durChapterIndex` 是**整表（含卷）的下标** ⭐⭐⭐
        //      ⇒ 我们传的 `start` 是「正文章」⇒ 要换算成整表下标 ⇒ 不能直接用 ✗⭐⭐⭐
        var startIndex = -1
        if let start {
            // 显式选了某一章（详情页目录里点的）⇒ 以它为准 ⭐⭐⭐
            let plainList = chapters.filter { !$0.isVolume }
            if let plainIndex = plainList.firstIndex(where: { $0.url == start.url }),
               let wholeIndex = converted.plainIndexes[safe: plainIndex] {
                startIndex = wholeIndex
            }
        }
        if startIndex < 0 {
            // 没显式选 ⇒ 用**书架仓里的进度**（崩溃保护：上次没写回 App 也不丢位置）⭐⭐⭐
            startIndex = library.shelf.book(book.cleanBookUrl)?.durChapterIndex ?? -1
        }
        if startIndex < 0 {
            // 兜底用轻阅存的进度 ⇒ ⚠️ **它是「正章节下标」** ⇒ 必须换算成柴阅的「整表下标」⭐⭐⭐
            startIndex = plainToWhole[safe: progressIndex] ?? -1
        }

        // ── ⑤ 书：轻阅的书 → 柴阅的书（带上进度）──────────────────────
        //    ⚠️ **必须是 `var`**：下面还要写 `totalChapterNum` / `durChapterTitle`（CI28 实锤）⭐⭐⭐
        var chaiyueBook = ChaiyueReaderAdapter.book(book, sourceName: source?.bookSourceName ?? book.sourceName,
                                                     chapterIndex: startIndex)
        chaiyueBook.totalChapterNum = chapters.filter { !$0.isVolume }.count
        if startIndex >= 0, startIndex < chapters.count {
            chaiyueBook.durChapterTitle = chapters[startIndex].title
        }
        // ⚠️ 这一本要**盖掉**镜像值（它带着刚算出来的起始章号）⭐⭐⭐
        library.shelf.add(chaiyueBook)

        // ── ⑥ 柴阅的 AppModel（阅读器的环境）────────────────────────────
        app = AppModel(library: library)
        self.chaiyueBook = chaiyueBook
        // ⚠️ 用柴阅的 `openReader` 而不是自己造 `ReaderLaunch`：
        //   · 它会按**书架里的最新记录**取书（带进度）⇒ 不会丢掉「读到哪了」⭐⭐⭐
        //   · 它把 `app.reader` 置位 ⇒ 宿主靠 `app.reader == nil` 感知「阅读器被关掉了」
        //     （柴阅的 `ReaderContainer.close()` 调 `app.closeReader()` ⇒ 置 nil）⭐⭐⭐
        // ⚠️⭐⭐⭐ **漫画模式走另一条 launch**（`app.media`，不是 `app.reader`）⭐⭐⭐⭐⭐
        //   柴阅的听书/漫画/短剧是**独立的媒体页**（`MediaLayer` 观察 `app.media`）⇒
        //   ⇒ 漫画模式**不能**置 `app.reader`（那是文字阅读器的信号）⭐⭐⭐
        switch mode {
        case .text:
            app.openReader(chaiyueBook)
            launch = app.reader ?? ReaderLaunch(book: chaiyueBook, origin: nil, coverKey: nil)
        case .comic:
            app.media = MediaLaunch(book: chaiyueBook, kind: .comic, origin: nil)
            launch = nil
        }

        // ── ⑦ 会话 ───────────────────────────────────────────────────
        //    ⭐⭐⭐ **会话必须先由宿主建好**（`readerSession(for:)` 内部会缓存）
        //      ⇒ 柴阅的 `ReaderContainer` 随后调 `app.library.readerSession(for:)` 拿到的
        //        **就是这一份** ⇒ 界面与宿主共用一个会话 ⇒ 进度不分叉 ⭐⭐⭐
        //      ⇒ 宿主不再另造 `ReaderModel`（包内 internal ⇒ 宿主看不见；而且位置本来就在会话里）⭐⭐⭐
        session = library.readerSession(for: launch.book)
    }

    // MARK: - 回写

    /// ⭐⭐⭐ **退出阅读：把进度回写回轻阅的书架** ⭐⭐⭐
    ///
    /// ⚠️ 柴阅把进度写进了**它自己的**书架仓 ⇒ 轻阅的书库看不到 ⇒ 必须搬回来 ⭐⭐⭐
    /// - Returns: 读到的章下标（**正章节下标**，轻阅口径；-1 = 没读到）
    @discardableResult
    func writeBackProgress(to libraryStore: LibraryStore?) -> Int {
        guard let libraryStore else { return -1 }
        let stored = library.shelf.book(qiBook.cleanBookUrl)
        // ⚠️ 位置以**会话里的实时位置**为准（界面翻到哪就是哪）
        //   ⇒ 柴阅的 `ReaderModel` 每次翻页都调 `session.updatePosition(...)` ⇒ 会话位置就是实时的 ⭐⭐⭐
        //   ⇒ 书架仓那份是 `ReaderSession.saveProgress()` 写的副本，做兜底 ⭐⭐⭐
        // ⚠️⭐⭐⭐ **漫画模式另算**（2026-11-26 · 漫画阅读器）⭐⭐⭐⭐⭐
        //   漫画的进度由柴阅的 **`MediaSession.save()`** 直接写进**书架仓**
        //   （`shelf.saveProgress(bookUrl:chapterIndex:chapterPos:…)`）⇒ **读书架仓就是实时的** ⭐⭐⭐
        //   ⇒ 而且漫画的 `position` 是**图片序号**、不是章号 ⇒ 绝不能用它当章下标 ⭐⭐⭐
        let live: Int
        switch mode {
        case .text: live = session.position.chapterIndex
        case .comic: live = stored?.durChapterIndex ?? -1
        }
        let whole = live >= 0 ? live : (stored?.durChapterIndex ?? -1)
        guard whole >= 0 else { return whole }
        // ⚠️⚠️ **口径换算**：柴阅给的是「整表下标（含卷）」，轻阅的 `lastChapterIndex`
        //   是「正章节下标」（老阅读器存的）⇒ 不换算 ⇒ 书架上会显示成错乱的章号 ⭐⭐⭐
        let plain = wholeToPlain[whole] ?? whole
        let title = stored?.durChapterTitle ?? qiChapters[safe: whole]?.title ?? ""
        libraryStore.saveProgress(bookID: qiBook.id, chapterIndex: plain, ratio: 0, chapterTitle: title)
        return plain
    }
}

// MARK: - 小工具

/// ⚠️ **文件私有**（不给整个 App 加扩展 ⇒ 以后别的模块想加同名扩展也不会撞）⭐⭐⭐
private extension Array {
    /// 安全下标（柴阅的目录是「整表（含卷）」，轻阅的章表口径不同 ⇒ 换算时越界很常见）⭐⭐⭐
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
