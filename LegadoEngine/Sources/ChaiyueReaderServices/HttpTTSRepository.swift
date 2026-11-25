import Foundation
import Observation
import ChaiyueModels

/// 在线朗读源仓库，按导入顺序保存
@MainActor
@Observable
public final class HttpTTSRepository {
    public private(set) var engines: [HttpTTS] = []
    @ObservationIgnored private let store: JSONFileStore<[HttpTTS]>

    public init(fileURL: URL) {
        store = JSONFileStore(url: fileURL) { [] }
        engines = Self.unique(store.current)
    }

    public var enabledEngines: [HttpTTS] {
        engines.filter(\.enabled)
    }

    public func engine(id: Int64) -> HttpTTS? {
        engines.first { $0.id == id }
    }

    /// 按 id 合并：已有的覆盖，新的追加
    @discardableResult
    public func importEngines(_ incoming: [HttpTTS]) -> ImportSummary {
        var summary = ImportSummary()
        for tts in Self.unique(incoming) {
            if let index = engines.firstIndex(where: { $0.id == tts.id }) {
                if engines[index] == tts {
                    summary.unchanged += 1
                } else {
                    engines[index] = tts
                    summary.updated += 1
                }
            } else {
                engines.append(tts)
                summary.added += 1
            }
        }
        persist()
        return summary
    }

    /// 恢复备份：整体替换
    public func replaceAll(_ items: [HttpTTS]) {
        engines = Self.unique(items)
        persist()
    }

    /// 新建或编辑后保存，更新 `lastUpdateTime`
    public func save(_ tts: HttpTTS) {
        var tts = tts
        tts.lastUpdateTime = Int64(Date().timeIntervalSince1970 * 1000)
        if let index = engines.firstIndex(where: { $0.id == tts.id }) {
            engines[index] = tts
        } else {
            engines.append(tts)
        }
        persist()
    }

    public func delete(_ ids: Set<Int64>) {
        engines.removeAll { ids.contains($0.id) }
        persist()
    }

    public func setEnabled(_ enabled: Bool, for ids: Set<Int64>) {
        for index in engines.indices where ids.contains(engines[index].id) {
            engines[index].enabled = enabled
        }
        persist()
    }

    public func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        engines.moveElements(fromOffsets: offsets, toOffset: destination)
        persist()
    }

    /// 导出为 Legado 格式的 JSON 数组
    public func export(_ ids: Set<Int64>? = nil) throws -> Data {
        let items = ids.map { set in engines.filter { set.contains($0.id) } } ?? engines
        return try SourceImport.export(items)
    }

    public func flush() {
        store.flush()
    }

    private func persist() {
        let snapshot = engines
        store.update { $0 = snapshot }
    }

    /// 同一 id 保留最后一个
    private static func unique(_ items: [HttpTTS]) -> [HttpTTS] {
        var last: [Int64: Int] = [:]
        for (index, item) in items.enumerated() { last[item.id] = index }
        return items.enumerated().filter { last[$0.element.id] == $0.offset }.map(\.element)
    }
}
