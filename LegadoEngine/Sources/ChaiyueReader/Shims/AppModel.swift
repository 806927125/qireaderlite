// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/App/AppModel.swift 搬运 + 【改造】**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码的改造版 ⭐⭐⭐
// 原文件：App/Sources/App/AppModel.swift
//
// ⭐⭐⭐⭐⭐ **改造点（与上游的 diff，请勿误删）**⭐⭐⭐⭐⭐
//   柴阅的 `AppModel` 是**整个 App 的根对象**（持有 `LibraryServices` / 书架 / 书源 / 灵动岛 / 音频播放器 /
//   导入 / 媒体播放 …）。我们只 vendor 了**阅读器**，不该把整个 App 层拖进来 ⭐⭐⭐
//   ⇒ 改造：`library` 换成**宿主注入的协议** `ChaiyueReaderLibrary` ⭐⭐⭐
//     · 宿主自己实现它（用宿主侧的书架/书源/阅读会话）⇒ **宿主造 `ReaderSession`**，包不持有 `LibraryServices` ⭐⭐⭐
//     · 柴阅阅读器源码里 `app.library.xxx` 的调用**一字未改** ⇒ 行为不变 ⭐⭐⭐
//   ⇒ 其余成员（`settings` / `speech` / `island` / `stats` / `voices` / `appearance` / `reader` / `coverFrames` …）保持原样 ⭐⭐⭐
import ChaiyueEngine
import ChaiyueModels
import ChaiyueReaderServices
import Foundation
import Observation

/// 宿主注入的「书源 + 书架 + 阅读会话」门面。
/// ⭐⭐ **宿主 App 侧实现它** ⇒ 轻阅自己的书架/书源/章节缓存直接接进柴阅阅读器 ⭐⭐
protocol ChaiyueReaderLibrary {
    /// 书架（书签、章节进度）
    var shelf: BookshelfRepository { get }
    /// 书源仓
    var sources: SourceRepository { get }
    /// 在线朗读源
    var httpTTS: HttpTTSRepository { get }
    /// 朗读音频加载器（柴阅 `SpeechAudioLoader`，在 ReaderServices 里）⭐⭐⭐
    var speechLoader: SpeechAudioLoader { get }
    /// 为一本书造阅读会话（宿主自己拼 `BookContentService` + `ContentProcessor` + `BookshelfRepository`）
    func readerSession(for book: Book) -> ReaderSession
    /// 书源事件回调（`java.*` 的回传给宿主）
    func callBack(_ event: SourceCallBackEvent, book: Book, chapter: BookChapter?)
}

/// 朗读时打断宿主音频播放的最小接口（柴阅用的是 `AudioBookPlayer`，那是媒体层，不在阅读器范围）
protocol ReaderAudioPausing: AnyObject {
    func pause()
}

/// 默认实现：没有音频播放器时什么都不做
final class ReaderAudioPauser: ReaderAudioPausing {
    init() {}
    func pause() {}
}

/// 阅读器的根状态对象（宿主用 `.environment(app)` 注入）
@Observable
final class AppModel {
    // MARK: - 依赖

    let library: ChaiyueReaderLibrary
    let settings: ReaderSettings
    let speech: SpeechController
    let appearance: AppearanceStore
    let island: IslandCenter
    let stats: ReadingStats
    let voices: VoiceCatalog
    let voiceStore: LocalVoiceStore
    let localVoice: LocalVoice
    let audio: ReaderAudioPausing

    // MARK: - 状态

    /// 打开阅读器的请求；宿主置位后呈现 `ReaderContainer`
    var reader: ReaderLaunch?
    /// 正在朗读的书（阅读器关闭后仍可回到阅读器）
    var speechBook: Book?
    /// 书源要求阅读器重新加载当前章节（`java.refreshContent`）
    var contentSignal: SourceSignal?
    /// 书源要求刷新登录界面（`java.reLoginView` / `java.upLoginData`）
    var loginSignal: SourceSignal?
    /// 可见封面在窗口中的位置（开书动画的起点），不参与界面刷新
    @ObservationIgnored var coverFrames: [String: CGRect] = [:]
    /// 阅读器在打开期间接管「朗读读完一章」的处理
    @ObservationIgnored var speechChapterFinished: (() -> Void)?

    init(library: ChaiyueReaderLibrary,
                settings: ReaderSettings = ReaderSettings(),
                speech: SpeechController = SpeechController(),
                appearance: AppearanceStore = AppearanceStore(),
                island: IslandCenter = IslandCenter(),
                stats: ReadingStats = ReadingStats(),
                voices: VoiceCatalog = VoiceCatalog(),
                voiceStore: LocalVoiceStore = LocalVoiceStore(),
                localVoice: LocalVoice = LocalVoice(),
                audio: ReaderAudioPausing = ReaderAudioPauser()) {
        self.library = library
        self.settings = settings
        self.speech = speech
        self.appearance = appearance
        self.island = island
        self.stats = stats
        self.voices = voices
        self.voiceStore = voiceStore
        self.localVoice = localVoice
        self.audio = audio
        speech.onChapterFinished = { [weak self] in self?.speechChapterFinished?() }
    }

    // MARK: - 导航

    /// 打开阅读器（文字书）。
    /// ⚠️ **不做媒体分流**：包里没有媒体播放页（听书/漫画/短剧不在阅读器范围）⇒ 永远置位 `reader` ⭐⭐
    func openReader(_ book: Book, coverKey: String? = nil) {
        let current = library.shelf.book(book.bookUrl) ?? book
        reader = ReaderLaunch(book: current, origin: coverKey.flatMap { coverFrames[$0] }, coverKey: coverKey)
    }

    /// 关闭阅读器（由 `ReaderContainer` 在合书动画结束时调用）
    func closeReader() {
        reader = nil
    }

    /// 书籍的内容形态（文字书 / 听书 / 漫画 / 短剧）
    func mediaKind(of book: Book) -> BookMediaKind {
        book.mediaKind(sourceType: library.sources.source(for: book.origin)?.bookSourceType)
    }

    /// 打开书籍详情（宿主可覆盖成自己的详情页）
    func openDetail(_ book: Book) {
        island.show("info.circle", book.name)
    }

    // MARK: - 书架

    /// 书架上已有同名同作者的其它来源时先确认覆盖；`add` 收到被覆盖的书籍地址（没有冲突时为 nil）
    func confirmShelfAdd(_ book: Book, add commit: @escaping (_ replacing: String?) -> Void) {
        commit(nil)
    }

    /// 该书能不能重新分章（本地 TXT 才需要重新切分）
    func canResplit(_ book: Book) -> Bool {
        book.isLocal
    }

    /// 书籍所属书源开启了自定义按钮
    func customButtonSource(for book: Book) -> BookSource? {
        guard !book.isLocal, let source = library.sources.source(for: book.origin), source.customButton else { return nil }
        return source
    }

    // MARK: - 朗读

    /// 朗读设置里选中的在线朗读源，其次是本地语音；都没有时为 nil（用系统语音）
    var onlineSpeech: SpeechController.Online? {
        if let tts = selectedEngine {
            return .http(tts, speechRate: settings.speechRate, loader: library.speechLoader)
        }
        guard usesLocalVoice else { return nil }
        return .local(settings.localVoice, speechRate: settings.speechRate, voice: localVoice)
    }

    /// 朗读中换了声音：立即从当前句改用新声音
    func applyVoiceChange() {
        guard speech.isActive else { return }
        speech.switchVoice(voiceID: settings.speechVoice, online: onlineSpeech)
    }

    /// 当前声音的名称
    var voiceName: String {
        onlineSpeech?.name ?? settings.speechVoice.flatMap { id in voices.voices.first { $0.id == id }?.name } ?? "系统语音"
    }

    /// 选中且启用的在线朗读源
    var selectedEngine: HttpTTS? {
        guard let id = settings.speechEngine, let tts = library.httpTTS.engine(id: id), tts.enabled else { return nil }
        return tts
    }

    var usesLocalVoice: Bool { selectedEngine == nil && settings.localVoice >= 0 && localVoiceReady }

    /// 读语音包状态以便下载完成后界面刷新。
    /// ⚠️ **降级说明**：本地语音已降级为系统 TTS（见 `LocalVoice.swift`）⇒ **不再需要语音包** ⇒ 恒为 true ⭐⭐
    var localVoiceReady: Bool { LocalVoice.isAvailable }
}
