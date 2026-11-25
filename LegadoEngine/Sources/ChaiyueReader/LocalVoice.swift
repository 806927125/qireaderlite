// ⭐⭐⭐⭐⭐ **平台条件编译补丁**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **为什么需要**：阅读器界面用满 UIKit（`UIScreen` / `UIApplication` / `UIImpactFeedbackGenerator` …）
//   ⇒ **iOS-only** ⇒ Linux 沙盒编不到 SwiftUI/UIKit ⇒ 若不隔离，**整个包的 Linux 编译门禁全废** ⭐⭐⭐
//   ⇒ 用 `#if canImport(UIKit)` 包裹：**Apple 平台功能完全不变**，Linux 上跳过这段界面代码 ⭐⭐⭐
//   ⇒ 与上游的 diff 仅此两行（去掉即可回到柴阅原样）⭐⭐⭐
// ⭐⭐⭐⭐⭐ **柴阅 `App/Sources/Reader/LocalVoice.swift` 的【降级改造版】**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️⚠️⚠️ **为什么必须降级**（与上游唯一的 diff，务必保留说明）⭐⭐⭐
//   原文件 `import SherpaTTS` ⇒ 依赖柴阅自带的 `Packages/SherpaTTS`（Kokoro 中文 v1.1 离线神经网络 TTS）。
//   **本仓库没有这个依赖**（它是带 ONNX Runtime 的原生二进制包，不能只靠源码 vendor）⭐⭐⭐
//   ⇒ 若原样保留，`swift build` 必然失败（`no such module 'SherpaTTS'`）⭐⭐⭐
//
// ⭐⭐⭐ **降级方案**（任务书第 2 条明确授权）：
//   **「本地神经语音包」⇒ 降级为系统 TTS（`AVSpeechSynthesizer`）** ⭐⭐⭐
//   · API 表面（`LocalVoice` 的类型、方法、静态属性）**完全保持不变** ⇒ 柴阅阅读器源码一行不用改 ⭐⭐⭐
//   · 音色编号沿用 Kokoro 的分段习惯（女声一段、男声一段），只是内容换成系统语音
//   · 合成结果同样产出 **WAV** ⇒ `SpeechController` 的 `AVAudioPlayer` 播放链路完全不变 ⭐⭐⭐
//   · 行为差异：**音质从「神经网络」降为「系统合成」**；**不再需要下载/加载 ONNX 模型**（⇒ 也就不会崩）⭐⭐⭐
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码的改造版 ⭐⭐⭐
#if canImport(SwiftUI)
import AVFoundation
import Foundation
import Observation
import ChaiyueEngine

/// 本地语音（**降级版**：系统 `AVSpeechSynthesizer`，非神经网络）
@Observable
final class LocalVoice {
    enum State: Equatable { case idle, loading, ready, failed }

    private(set) var state: State = .idle
    @ObservationIgnored private var engine: SystemVoiceEngine?
    @ObservationIgnored private var loading: Task<SystemVoiceEngine?, Never>?
    @ObservationIgnored private let queue = DispatchQueue(label: "chaiyue.systemtts", qos: .userInitiated)
    @ObservationIgnored private var cache: [String: Task<TTSAudio, Error>] = [:]
    @ObservationIgnored private var order: [String] = []
    private static let capacity = 6
    /// 降级后不再做多线程推理，保留这个开关只为兼容柴阅的调用方
    static var threads = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount))
    static var provider = "cpu"

    /// 默认音色：女声 1
    static let defaultSpeaker = SystemVoiceEngine.femaleVoices.lowerBound
    static let female = Array(SystemVoiceEngine.femaleVoices)
    static let male = Array(SystemVoiceEngine.maleVoices)

    /// 降级后不再需要模型目录（保留属性只为兼容调用方）
    static var directory: URL? {
        if LocalVoiceStore.isReady { return LocalVoiceStore.directory }
        return Bundle.main.url(forResource: "Kokoro", withExtension: nil)
    }

    /// 降级后系统语音永远可用 ⇒ 恒为 true（原本要求 Kokoro 模型就位）
    static var isAvailable: Bool { true }

    static func name(of speaker: Int) -> String {
        if SystemVoiceEngine.maleVoices.contains(speaker) { return "男声 \(speaker - SystemVoiceEngine.maleVoices.lowerBound + 1)" }
        return "女声 \(max(1, speaker - SystemVoiceEngine.femaleVoices.lowerBound + 1))"
    }

    /// 应用的语速 0.25–0.75（0.5 为正常）换成引擎倍速
    static func pace(_ speechRate: Double) -> Float { Float(min(max(speechRate, 0.25), 0.75) / 0.5) }

    func audio(_ text: String, speaker: Int, speed: Float) async throws -> TTSAudio {
        let key = "\(speaker)|\(speed)|\(text)"
        if let task = cache[key] { return try await task.value }
        let task = Task<TTSAudio, Error> { [weak self] in
            guard let self, let engine = await self.prepare() else { throw LocalVoiceError.unavailable }
            try Task.checkCancellation()
            let data: Data? = await withCheckedContinuation { continuation in
                self.queue.async { continuation.resume(returning: engine.wav(text: text, speaker: speaker, speed: speed)) }
            }
            guard let data else { throw LocalVoiceError.empty }
            return TTSAudio(data: data, contentType: "audio/wav")
        }
        remember(key, task)
        do {
            return try await task.value
        } catch {
            if cache[key] == task { forget(key) }
            throw error
        }
    }

    func prefetch(_ text: String, speaker: Int, speed: Float) {
        Task { _ = try? await audio(text, speaker: speaker, speed: speed) }
    }

    /// 合成已在队列里的句子会照常算完，只是结果被丢弃
    func cancelAll() {
        cache.values.forEach { $0.cancel() }
        cache = [:]
        order = []
    }

    @discardableResult
    func prepare() async -> SystemVoiceEngine? {
        if let engine { return engine }
        if let loading { return await loading.value }
        state = .loading
        let queue = queue
        let threads = Self.threads
        let provider = Self.provider
        let task = Task<SystemVoiceEngine?, Never> {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: SystemVoiceEngine(directory: Self.directory, threads: threads, provider: provider))
                }
            }
        }
        loading = task
        let engine = await task.value
        loading = nil
        self.engine = engine
        state = engine == nil ? .failed : .ready
        return engine
    }

    private func remember(_ key: String, _ task: Task<TTSAudio, Error>) {
        cache[key] = task
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > Self.capacity { forget(order[0]) }
    }

    private func forget(_ key: String) {
        cache[key] = nil
        order.removeAll { $0 == key }
    }
}

enum LocalVoiceError: LocalizedError {
    case unavailable, empty

    var errorDescription: String? {
        switch self {
        case .unavailable: "本地语音模型加载失败"
        case .empty: "本地语音合成失败"
        }
    }
}

// MARK: - 降级引擎：系统 TTS

/// 降级版的「本地语音引擎」：用 `AVSpeechSynthesizer` 合成，产出 WAV。
/// 接口对齐柴阅的 `KokoroEngine`（`wav(text:speaker:speed:)`），使上层代码零改动。
final class SystemVoiceEngine: @unchecked Sendable {
    /// 女声一段、男声一段（沿用 Kokoro 的分段习惯，只是内容换成系统语音）
    static let femaleVoices = 1...8
    static let maleVoices = 9...16

    let directory: URL?
    let threads: Int
    let provider: String

    init(directory: URL?, threads: Int, provider: String) {
        self.directory = directory
        self.threads = threads
        self.provider = provider
    }

    /// 合成一句话，返回 WAV 数据；失败返回 nil（上层会转成「本地语音合成失败」）
    func wav(text: String, speaker: Int, speed: Float) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = Self.voice(for: speaker)
        utterance.rate = Self.rate(for: speed)
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0

        let collector = PCMCollector()
        let semaphore = DispatchSemaphore(value: 0)
        synthesizer.write(utterance) { buffer in
            guard let buffer else {
                semaphore.signal()
                return
            }
            collector.append(buffer)
            if buffer.audioLength == 0 { semaphore.signal() }
        }
        // `write` 的回调在内部串行队列上触发；最多等 30 秒，超时按已有数据返回
        let deadline = DispatchTime.now() + .seconds(30)
        while semaphore.wait(timeout: .now()) == .timedOut {
            if DispatchTime.now() >= deadline { break }
        }
        return collector.wavData()
    }

    /// 选一个系统语音：优先中文，系统里没有中文就用默认语音
    private static func voice(for speaker: Int) -> AVSpeechSynthesisVoice? {
        let all = AVSpeechSynthesisVoice.speechVoices()
        let chinese = all.filter { $0.language.hasPrefix("zh") }
        let pool = chinese.isEmpty ? all : chinese
        guard !pool.isEmpty else { return nil }
        let index = max(0, speaker - femaleVoices.lowerBound)
        return pool[index % pool.count]
    }

    /// 倍速：柴阅的 0.25–0.75 映射到系统语速区间（0.5 为常速）
    private static func rate(for speed: Float) -> Float {
        let normal = Float(AVSpeechUtteranceDefaultSpeechRate)
        let scaled = normal * max(0.4, min(1.6, speed))
        return max(AVSpeechUtteranceMinimumSpeechRate, min(AVSpeechUtteranceMaximumSpeechRate, scaled))
    }
}

/// 收集 `AVSpeechSynthesizer.write` 回调里分块给出的 PCM，拼成 WAV
private final class PCMCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var pcm: [Int16] = []
    private var sampleRate = 22_050
    private var channels = 1

    func append(_ buffer: AVAudioBuffer) {
        guard let pcmBuffer = buffer as? AVAudioPCMBuffer,
              let channelsData = pcmBuffer.floatChannelData else { return }
        let frames = Int(pcmBuffer.frameLength)
        guard frames > 0 else { return }
        let format = pcmBuffer.format
        lock.lock()
        defer { lock.unlock() }
        sampleRate = Int(format.sampleRate)
        channels = max(1, Int(format.channelCount))
        pcm.reserveCapacity(pcm.count + frames * channels)
        for frame in 0..<frames {
            for channel in 0..<channels {
                let value = max(-1, min(1, channelsData[channel][frame]))
                pcm.append(Int16(value * Float(Int16.max)))
            }
        }
    }

    func wavData() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !pcm.isEmpty else { return nil }
        var data = Data()
        let byteCount = UInt32(pcm.count * 2)
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        data.append(contentsOf: Array("RIFF".utf8))
        append32(36 + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)
        append16(1)                                              // PCM
        append16(UInt16(channels))
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * channels * 2))             // 字节率
        append16(UInt16(channels * 2))                          // 块对齐
        append16(16)                                            // 位深
        data.append(contentsOf: Array("data".utf8))
        append32(byteCount)
        for sample in pcm { append16(UInt16(bitPattern: sample)) }
        return data
    }
}
#endif  // #if canImport(UIKit)
