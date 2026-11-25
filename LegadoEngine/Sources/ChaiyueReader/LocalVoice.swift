import Foundation
import Observation
import ChaiyueEngine
import SherpaTTS

/// 本地神经语音（Kokoro 中文 v1.1，离线）：第一次用到时在后台加载模型，按句合成并缓存最近几句
@Observable
final class LocalVoice {
    enum State: Equatable { case idle, loading, ready, failed }

    private(set) var state: State = .idle
    @ObservationIgnored private var engine: KokoroEngine?
    @ObservationIgnored private var loading: Task<KokoroEngine?, Never>?
    @ObservationIgnored private let queue = DispatchQueue(label: "chaiyue.kokoro", qos: .userInitiated)
    @ObservationIgnored private var cache: [String: Task<TTSAudio, Error>] = [:]
    @ObservationIgnored private var order: [String] = []
    private static let capacity = 6
    /// iPhone 17 Pro 实测 4 线程最快，再多反而互相抢核
    static var threads = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount))
    static var provider = "cpu"

    /// 默认音色：女声 1（zf_001）
    static let defaultSpeaker = KokoroEngine.femaleVoices.lowerBound
    static let female = Array(KokoroEngine.femaleVoices)
    static let male = Array(KokoroEngine.maleVoices)

    static var directory: URL? {
        if LocalVoiceStore.isReady { return LocalVoiceStore.directory }
        guard let url = Bundle.main.url(forResource: "Kokoro", withExtension: nil),
              ["model.onnx", "model.int8.onnx"].contains(where: {
                  FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
              }) else { return nil }
        return url
    }

    static var isAvailable: Bool { directory != nil }

    static func name(of speaker: Int) -> String {
        if KokoroEngine.maleVoices.contains(speaker) { return "男声 \(speaker - KokoroEngine.maleVoices.lowerBound + 1)" }
        return "女声 \(max(1, speaker - KokoroEngine.femaleVoices.lowerBound + 1))"
    }

    /// 应用的语速 0.25–0.75（0.5 为正常）换成 Kokoro 的倍速
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
    func prepare() async -> KokoroEngine? {
        if let engine { return engine }
        if let loading { return await loading.value }
        guard let directory = Self.directory else {
            state = .failed
            return nil
        }
        state = .loading
        let queue = queue
        let threads = Self.threads
        let provider = Self.provider
        let task = Task<KokoroEngine?, Never> {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: KokoroEngine(directory: directory, threads: threads, provider: provider))
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
