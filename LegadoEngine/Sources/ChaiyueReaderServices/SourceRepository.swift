import Foundation
import Observation
import ChaiyueModels

/// 书源仓库：增删改、启用、分组、排序与持久化（不负责解析）
@MainActor
@Observable
public final class SourceRepository {
    public private(set) var sources: [BookSource] = []
    @ObservationIgnored private let store: JSONFileStore<[BookSource]>

    public init(fileURL: URL) {
        store = JSONFileStore(url: fileURL) { [] }
        sources = store.current.sorted(by: Self.ordered)
    }

    nonisolated static func ordered(_ a: BookSource, _ b: BookSource) -> Bool {
        if a.customOrder != b.customOrder { return a.customOrder < b.customOrder }
        return a.bookSourceName.localizedStandardCompare(b.bookSourceName) == .orderedAscending
    }

    public var enabledSources: [BookSource] { sources.filter(\.enabled) }

    public var exploreSources: [BookSource] {
        sources.filter { $0.enabled && $0.enabledExplore && $0.hasExplore }
    }

    /// 所有分组，按首次出现顺序
    public var groups: [String] {
        var seen = Set<String>()
        return sources.flatMap(\.groups).filter { seen.insert($0).inserted }
    }

    public func source(for url: String) -> BookSource? {
        sources.first { $0.bookSourceUrl == url }
    }

    /// 导入：按 bookSourceUrl 合并，已存在的保留原排序
    @discardableResult
    public func importSources(_ incoming: [BookSource]) -> ImportSummary {
        var summary = ImportSummary()
        var indexByURL: [String: Int] = [:]
        for (index, source) in sources.enumerated() where indexByURL[source.bookSourceUrl] == nil {
            indexByURL[source.bookSourceUrl] = index
        }
        var nextOrder = (sources.map(\.customOrder).max() ?? 0) + 1
        for var source in incoming {
            if let index = indexByURL[source.bookSourceUrl] {
                source.customOrder = sources[index].customOrder
                if sources[index] == source {
                    summary.unchanged += 1
                } else {
                    sources[index] = source
                    summary.updated += 1
                }
            } else {
                source.customOrder = nextOrder
                nextOrder += 1
                indexByURL[source.bookSourceUrl] = sources.count
                sources.append(source)
                summary.added += 1
            }
        }
        persist()
        return summary
    }

    /// 恢复备份：整体替换，沿用备份中的排序
    public func replaceAll(_ items: [BookSource]) {
        var seen = Set<String>()
        sources = items.filter { seen.insert($0.bookSourceUrl).inserted }.sorted(by: Self.ordered)
        persist()
    }

    /// 保存编辑结果；`originalURL` 用于处理修改了 bookSourceUrl 的情况
    public func save(_ source: BookSource, originalURL: String? = nil) {
        let key = originalURL ?? source.bookSourceUrl
        if let index = sources.firstIndex(where: { $0.bookSourceUrl == key }) {
            sources[index] = source
        } else {
            var source = source
            source.customOrder = (sources.map(\.customOrder).max() ?? 0) + 1
            sources.append(source)
        }
        if key != source.bookSourceUrl {
            sources.removeAll { $0.bookSourceUrl == source.bookSourceUrl && $0 != source }
        }
        persist()
    }

    public func delete(_ urls: Set<String>) {
        sources.removeAll { urls.contains($0.bookSourceUrl) }
        persist()
    }

    public func setEnabled(_ enabled: Bool, for urls: Set<String>) {
        mutate(urls) { $0.enabled = enabled }
    }

    public func setExploreEnabled(_ enabled: Bool, for urls: Set<String>) {
        mutate(urls) { $0.enabledExplore = enabled }
    }

    public func setGroup(_ group: String?, for urls: Set<String>) {
        mutate(urls) { $0.bookSourceGroup = group?.isEmpty == true ? nil : group }
    }

    public func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        sources.moveElements(fromOffsets: offsets, toOffset: destination)
        for index in sources.indices {
            sources[index].customOrder = index
        }
        persist()
    }

    /// 导出为 Legado 兼容 JSON；`urls` 为空时导出全部
    public func export(_ urls: Set<String>? = nil) throws -> Data {
        let items = urls.map { set in sources.filter { set.contains($0.bookSourceUrl) } } ?? sources
        return try SourceImport.export(items)
    }

    public func flush() {
        store.flush()
    }

    private func mutate(_ urls: Set<String>, _ body: (inout BookSource) -> Void) {
        for index in sources.indices where urls.contains(sources[index].bookSourceUrl) {
            body(&sources[index])
        }
        persist()
    }

    private func persist() {
        let snapshot = sources
        store.update { $0 = snapshot }
    }
}
