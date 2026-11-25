// ⭐⭐⭐⭐⭐ **平台条件编译补丁**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **为什么需要**：阅读器界面用满 UIKit（`UIScreen` / `UIApplication` / `UIImpactFeedbackGenerator` …）
//   ⇒ **iOS-only** ⇒ Linux 沙盒编不到 SwiftUI/UIKit ⇒ 若不隔离，**整个包的 Linux 编译门禁全废** ⭐⭐⭐
//   ⇒ 用 `#if canImport(UIKit)` 包裹：**Apple 平台功能完全不变**，Linux 上跳过这段界面代码 ⭐⭐⭐
//   ⇒ 与上游的 diff 仅此两行（去掉即可回到柴阅原样）⭐⭐⭐
import AVFoundation
import MediaPlayer
import Observation
import ChaiyueModels
import ChaiyueReaderServices
import ChaiyueEngine

/// 朗读：按句排队，播报时回报当前句在章节稳定文本中的范围，读完一章交给阅读器翻到下一章继续。
/// 系统语音交给 AVSpeechSynthesizer 排队；在线朗读源与本地神经语音逐句合成后用 AVAudioPlayer 播放，并预取后面两句。
/// 在线合成失败时本章余下部分改用系统语音，直到停止朗读前不再请求在线朗读源
@Observable
final class SpeechController {
    /// 逐句合成的声音来源：在线朗读源或本地神经语音
    struct Online {
        /// 引擎、音色与语速的标识，变化时丢弃旧的缓存与预取
        let key: String
        let name: String
        let audio: @MainActor (String) async throws -> TTSAudio
        let prefetch: @MainActor (String) -> Void
        let cancelAll: @MainActor () -> Void

        static func http(_ tts: HttpTTS, speechRate: Double, loader: SpeechAudioLoader) -> Online {
            let speed = HttpTTS.speakSpeed(fromSpeechRate: Float(speechRate))
            return Online(key: "tts-\(tts.id)-\(speed)", name: tts.name.isEmpty ? "在线朗读" : tts.name.withoutEmoji,
                          audio: { try await loader.audio(tts, text: $0, speed: speed) },
                          prefetch: { loader.prefetch(tts, text: $0, speed: speed) },
                          cancelAll: { loader.cancelAll() })
        }

        static func local(_ speaker: Int, speechRate: Double, voice: LocalVoice) -> Online {
            let pace = LocalVoice.pace(speechRate)
            return Online(key: "local-\(speaker)-\(pace)", name: LocalVoice.name(of: speaker),
                          audio: { try await voice.audio($0, speaker: speaker, speed: pace) },
                          prefetch: { voice.prefetch($0, speaker: speaker, speed: pace) },
                          cancelAll: { voice.cancelAll() })
        }
    }

    enum State: Equatable {
        case idle, speaking, paused
    }

    private(set) var state: State = .idle
    private(set) var bookName = ""
    private(set) var chapterTitle = ""
    private(set) var chapterIndex = 0
    /// 正在朗读的句子（稳定偏移范围）
    private(set) var spokenRange: NSRange?
    /// 定时关闭的截止时间
    private(set) var sleepDeadline: Date?
    /// 逐句合成的声音正在等当前句的音频
    private(set) var buffering = false

    @ObservationIgnored var onChapterFinished: (() -> Void)?
    /// 在线朗读失败、已改用系统语音时回调错误说明
    @ObservationIgnored var onOnlineFailure: ((String) -> Void)?
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let proxy = SpeechDelegateProxy()
    @ObservationIgnored private let playerProxy = AudioPlayerProxy()
    @ObservationIgnored private var online: Online?
    @ObservationIgnored private var onlineFailed = false
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var current = 0
    @ObservationIgnored private var ranges: [ObjectIdentifier: NSRange] = [:]
    @ObservationIgnored private var lastUtterance: ObjectIdentifier?
    @ObservationIgnored private var sentences: [NSRange] = []
    @ObservationIgnored private var text: NSString = ""
    @ObservationIgnored private var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    @ObservationIgnored private var voice: AVSpeechSynthesisVoice?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    @ObservationIgnored private var commandsInstalled = false

    var isActive: Bool { state != .idle }

    /// 当前是否在用在线朗读源
    var isOnline: Bool { online != nil }

    init() {
        synthesizer.delegate = proxy
        proxy.onStart = { [weak self] id in Task { @MainActor in self?.didStart(id) } }
        proxy.onFinish = { [weak self] id in Task { @MainActor in self?.didFinish(id) } }
        playerProxy.onFinish = { [weak self] id in Task { @MainActor in self?.playerFinished(id) } }
        playerProxy.onError = { [weak self] id in Task { @MainActor in self?.playerFailed(id) } }
    }

    func speak(text: String, from offset: Int, chapterIndex: Int, title: String, book: String, rate: Double, voiceID: String?,
               online: Online? = nil) {
        stopSynth()
        self.text = text as NSString
        self.chapterIndex = chapterIndex
        chapterTitle = title
        bookName = book
        self.rate = Float(min(max(rate, 0.1), 0.9))
        voice = voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? AVSpeechSynthesisVoice(language: "zh-CN")
        if online?.key != self.online?.key { self.online?.cancelAll() }
        self.online = onlineFailed ? nil : online
        sentences = Self.split(self.text)
        activateSession()
        let start = sentences.firstIndex { NSMaxRange($0) > offset } ?? sentences.count
        state = sentences.isEmpty ? .idle : .speaking
        if self.online != nil { playOnline(from: start) } else { enqueue(from: start) }
        updateNowPlaying()
    }

    func pause() {
        guard state == .speaking else { return }
        if online != nil {
            player?.pause()
        } else {
            synthesizer.pauseSpeaking(at: .word)
        }
        state = .paused
        updateNowPlaying()
    }

    func resume() {
        guard state == .paused else { return }
        state = .speaking
        if online != nil {
            player?.play()
        } else {
            synthesizer.continueSpeaking()
        }
        updateNowPlaying()
    }

    func toggle() {
        state == .speaking ? pause() : resume()
    }

    func stop() {
        stopSynth()
        online?.cancelAll()
        online = nil
        onlineFailed = false
        state = .idle
        spokenRange = nil
        sleepTask?.cancel()
        sleepDeadline = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 朗读中换声音：从正在读的句子起改用新声音
    func switchVoice(voiceID: String?, online: Online?) {
        guard state != .idle else { return }
        let start = spokenRange.flatMap { sentences.firstIndex(of: $0) } ?? current
        stopSynth()
        voice = voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? AVSpeechSynthesisVoice(language: "zh-CN")
        if online?.key != self.online?.key { self.online?.cancelAll() }
        onlineFailed = false
        self.online = online
        state = .speaking
        if online != nil { playOnline(from: start) } else { enqueue(from: start) }
        updateNowPlaying()
    }

    /// 跳到上一句或下一句
    func skip(_ delta: Int) {
        guard let current = spokenRange, let index = sentences.firstIndex(of: current) else { return }
        let target = min(max(0, index + delta), sentences.count - 1)
        stopSynth()
        state = .speaking
        if online != nil { playOnline(from: target) } else { enqueue(from: target) }
    }

    func setSleep(minutes: Int?) {
        sleepTask?.cancel()
        guard let minutes else {
            sleepDeadline = nil
            return
        }
        sleepDeadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    // MARK: - 内部

    private func stopSynth() {
        ranges = [:]
        lastUtterance = nil
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        fetchTask?.cancel()
        fetchTask = nil
        player?.stop()
        player = nil
        buffering = false
    }

    // MARK: 在线朗读

    private func playOnline(from index: Int) {
        guard let online else { return }
        fetchTask?.cancel()
        player?.stop()
        player = nil
        // 只有标点、空白的句子不送去合成
        var index = index
        while index < sentences.count, !Self.isSpeakable(sentence(at: index)) { index += 1 }
        guard index < sentences.count else {
            buffering = false
            state = .idle
            onChapterFinished?()
            return
        }
        current = index
        buffering = true
        let range = sentences[index]
        let line = sentence(at: index)
        for next in (index + 1)..<min(index + 3, sentences.count) {
            let value = sentence(at: next)
            if Self.isSpeakable(value) { online.prefetch(value) }
        }
        fetchTask = Task { [weak self] in
            do {
                let audio = try await online.audio(line)
                guard let self, !Task.isCancelled else { return }
                try self.play(audio, range: range)
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.fallBack(from: index, error: error)
            }
        }
    }

    private func play(_ audio: TTSAudio, range: NSRange) throws {
        guard audio.format.isNativelyPlayable || audio.format == .unknown else {
            throw SpeechPlaybackError.unsupported(audio.format.rawValue)
        }
        let player = try AVAudioPlayer(data: audio.data, fileTypeHint: Self.fileTypeHint(audio.format))
        player.delegate = playerProxy
        player.prepareToPlay()
        self.player = player
        buffering = false
        spokenRange = range
        if state == .speaking { player.play() }
    }

    private func playerFinished(_ id: ObjectIdentifier) {
        guard let player, ObjectIdentifier(player) == id, online != nil else { return }
        self.player = nil
        playOnline(from: current + 1)
    }

    private func playerFailed(_ id: ObjectIdentifier) {
        guard let player, ObjectIdentifier(player) == id else { return }
        self.player = nil
        fallBack(from: current, error: SpeechPlaybackError.decode)
    }

    /// 本章余下的句子改用系统语音
    private func fallBack(from index: Int, error: Error) {
        buffering = false
        online?.cancelAll()
        online = nil
        onlineFailed = true
        onOnlineFailure?((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        guard state != .idle else { return }
        let paused = state == .paused
        enqueue(from: index)
        if paused { synthesizer.pauseSpeaking(at: .immediate) }
    }

    private func sentence(at index: Int) -> String {
        text.substring(with: sentences[index]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func isSpeakable(_ sentence: String) -> Bool {
        sentence.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    private static func fileTypeHint(_ format: TTSAudio.Format) -> String? {
        switch format {
        case .mp3: AVFileType.mp3.rawValue
        case .wav: AVFileType.wav.rawValue
        case .m4a: AVFileType.m4a.rawValue
        case .caf: AVFileType.caf.rawValue
        case .aac: "public.aac-audio"
        case .flac: "org.xiph.flac"
        case .ogg, .webm, .unknown: nil
        }
    }

    private func enqueue(from index: Int) {
        guard index < sentences.count else {
            state = .idle
            onChapterFinished?()
            return
        }
        for range in sentences[index...] {
            let utterance = AVSpeechUtterance(string: text.substring(with: range))
            utterance.rate = rate
            utterance.voice = voice
            utterance.postUtteranceDelay = 0.02
            let id = ObjectIdentifier(utterance)
            ranges[id] = range
            lastUtterance = id
            synthesizer.speak(utterance)
        }
    }

    private func didStart(_ id: ObjectIdentifier) {
        guard let range = ranges[id] else { return }
        spokenRange = range
    }

    private func didFinish(_ id: ObjectIdentifier) {
        guard ranges[id] != nil else { return }
        ranges[id] = nil
        if id == lastUtterance {
            lastUtterance = nil
            onChapterFinished?()
        }
    }

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        installRemoteCommands()
    }

    private func installRemoteCommands() {
        guard !commandsInstalled else { return }
        commandsInstalled = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor in self?.toggle() }
            return .success
        }
    }

    private func updateNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: chapterTitle,
            MPMediaItemPropertyArtist: bookName,
            MPNowPlayingInfoPropertyPlaybackRate: state == .speaking ? 1.0 : 0.0,
        ]
    }

    /// 按句末标点与换行切句，保留标点；过长的句子按逗号再切
    nonisolated static func split(_ text: NSString) -> [NSRange] {
        let enders: Set<unichar> = Set("。！？；!?;…\n".utf16)
        let commas: Set<unichar> = Set("，,、：:".utf16)
        var result: [NSRange] = []
        var start = 0
        let length = text.length
        func push(_ end: Int) {
            var s = start
            while s < end, let scalar = UnicodeScalar(text.character(at: s)), CharacterSet.whitespacesAndNewlines.contains(scalar) { s += 1 }
            if end > s { result.append(NSRange(location: s, length: end - s)) }
            start = end
        }
        var i = 0
        while i < length {
            let c = text.character(at: i)
            if enders.contains(c) {
                var end = i + 1
                // 连续的标点与右引号并入本句
                while end < length, enders.contains(text.character(at: end)) || "”’」』）)".utf16.contains(text.character(at: end)) {
                    end += 1
                }
                push(end)
                i = end
                continue
            }
            if i - start > 80, commas.contains(c) {
                push(i + 1)
            }
            i += 1
        }
        if start < length { push(length) }
        return result
    }
}

struct SystemVoice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let language: String
    let quality: Int

    /// 地区与音质，如「普通话 · 增强」
    var detail: String {
        let region: String = switch language {
        case "zh-HK": "粤语"
        case "zh-TW": "台湾"
        default: "普通话"
        }
        let grade: String? = switch AVSpeechSynthesisVoiceQuality(rawValue: quality) {
        case .premium: "高级"
        case .enhanced: "增强"
        default: nil
        }
        return BookText.join(region, grade)
    }
}

/// 系统中文语音；真机上枚举一次要好几秒，只在后台取一次
@Observable
final class VoiceCatalog {
    private(set) var voices: [SystemVoice] = []
    @ObservationIgnored private var loading: Task<Void, Never>?

    func load() {
        guard loading == nil else { return }
        loading = Task {
            voices = await Task.detached(priority: .utility) {
                AVSpeechSynthesisVoice.speechVoices()
                    .filter { $0.language.hasPrefix("zh") }
                    .map { SystemVoice(id: $0.identifier, name: $0.name, language: $0.language, quality: $0.quality.rawValue) }
                    .sorted { ($0.quality, $0.name) > ($1.quality, $1.name) }
            }.value
        }
    }
}

enum SpeechPlaybackError: LocalizedError {
    case unsupported(String)
    case decode

    var errorDescription: String? {
        switch self {
        case .unsupported(let format): "暂不支持播放 \(format) 格式的朗读音频"
        case .decode: "朗读音频无法解码"
        }
    }
}

/// AVAudioPlayer 的代理回调转成标识符后交给主线程处理
nonisolated final class AudioPlayerProxy: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    var onFinish: (@Sendable (ObjectIdentifier) -> Void)?
    var onError: (@Sendable (ObjectIdentifier) -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if flag { onFinish?(ObjectIdentifier(player)) } else { onError?(ObjectIdentifier(player)) }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        onError?(ObjectIdentifier(player))
    }
}

/// AVSpeechSynthesizer 的代理回调可能来自任意线程，转成标识符后交给主线程处理
nonisolated final class SpeechDelegateProxy: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    var onStart: (@Sendable (ObjectIdentifier) -> Void)?
    var onFinish: (@Sendable (ObjectIdentifier) -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        onStart?(ObjectIdentifier(utterance))
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish?(ObjectIdentifier(utterance))
    }
}
#endif  // #if canImport(UIKit)
