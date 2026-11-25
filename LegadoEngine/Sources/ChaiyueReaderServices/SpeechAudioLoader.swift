import Foundation
import ChaiyueModels
import ChaiyueEngine

/// 在线朗读的合成与预取：同一朗读源、文字、语速的请求共用一次合成，结果在内存中保留最近 `capacity` 句。
/// 预取的句子在正式请求前完成时直接返回；失败的结果不保留，下次请求重新合成
@MainActor
public final class SpeechAudioLoader {
    public var capacity = 6
    /// 见 `HttpTTSEngine.retryCount`
    public var retryCount = 2

    private struct Key: Hashable {
        let tts: HttpTTS
        let text: String
        let speed: Int
    }

    private let environment: SourceEnvironment
    private var tasks: [Key: Task<TTSAudio, Error>] = [:]
    private var order: [Key] = []

    public init(environment: SourceEnvironment) {
        self.environment = environment
    }

    /// 合成一句。调用方任务取消时，这一句的合成也会取消
    public func audio(_ tts: HttpTTS, text: String, speed: Int = HttpTTS.defaultSpeakSpeed) async throws -> TTSAudio {
        let key = Key(tts: tts, text: text, speed: speed)
        let task = task(for: key)
        do {
            let audio = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            settle(key, task, succeeded: true)
            return audio
        } catch {
            settle(key, task, succeeded: false)
            throw error
        }
    }

    /// 后台提前合成，之后用相同参数调用 `audio` 时直接取结果
    public func prefetch(_ tts: HttpTTS, text: String, speed: Int = HttpTTS.defaultSpeakSpeed) {
        _ = task(for: Key(tts: tts, text: text, speed: speed))
    }

    /// 是否已合成完成（不含进行中的）
    public func isReady(_ tts: HttpTTS, text: String, speed: Int = HttpTTS.defaultSpeakSpeed) -> Bool {
        readyKeys.contains(Key(tts: tts, text: text, speed: speed))
    }

    /// 停止朗读、切换朗读源或语速时调用：取消全部进行中的合成并清空缓存
    public func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
        order = []
        readyKeys = []
    }

    private var readyKeys = Set<Key>()

    private func task(for key: Key) -> Task<TTSAudio, Error> {
        if let task = tasks[key] {
            order.removeAll { $0 == key }
            order.append(key)
            return task
        }
        let engine = HttpTTSEngine(tts: key.tts, environment: environment, retryCount: retryCount)
        let task = Task { try await engine.synthesize(key.text, speed: key.speed) }
        tasks[key] = task
        order.append(key)
        while order.count > max(capacity, 1) {
            let evicted = order.removeFirst()
            tasks.removeValue(forKey: evicted)?.cancel()
            readyKeys.remove(evicted)
        }
        Task { [weak self] in
            let result = await task.result
            if case .success = result {
                self?.settle(key, task, succeeded: true)
            } else {
                self?.settle(key, task, succeeded: false)
            }
        }
        return task
    }

    private func settle(_ key: Key, _ task: Task<TTSAudio, Error>, succeeded: Bool) {
        guard tasks[key] == task else { return }
        if succeeded {
            readyKeys.insert(key)
        } else {
            tasks.removeValue(forKey: key)
            order.removeAll { $0 == key }
        }
    }
}
