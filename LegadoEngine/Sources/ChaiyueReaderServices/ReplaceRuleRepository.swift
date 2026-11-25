import Foundation
import Observation
import ChaiyueModels

/// 替换净化规则仓库
@MainActor
@Observable
public final class ReplaceRuleRepository {
    public private(set) var rules: [ReplaceRule] = []
    @ObservationIgnored private let store: JSONFileStore<[ReplaceRule]>

    public init(fileURL: URL) {
        store = JSONFileStore(url: fileURL) { [] }
        rules = store.current.sorted { $0.order < $1.order }
    }

    /// 已启用的规则，按 order 排序
    public var enabledRules: [ReplaceRule] {
        rules.filter { $0.isEnabled && !$0.pattern.isEmpty }
    }

    public var groups: [String] {
        var seen = Set<String>()
        return rules.compactMap(\.group).flatMap { ReplaceRule.splitScope($0) }.filter { seen.insert($0).inserted }
    }

    @discardableResult
    public func importRules(_ incoming: [ReplaceRule]) -> ImportSummary {
        var summary = ImportSummary()
        for rule in incoming {
            if let index = rules.firstIndex(where: { $0.id == rule.id }) {
                if rules[index] == rule {
                    summary.unchanged += 1
                } else {
                    rules[index] = rule
                    summary.updated += 1
                }
            } else {
                rules.append(rule)
                summary.added += 1
            }
        }
        rules.sort { $0.order < $1.order }
        persist()
        return summary
    }

    /// 恢复备份：整体替换
    public func replaceAll(_ items: [ReplaceRule]) {
        var seen = Set<Int64>()
        rules = items.filter { seen.insert($0.id).inserted }.sorted { $0.order < $1.order }
        persist()
    }

    public func save(_ rule: ReplaceRule) {
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = rule
        } else {
            var rule = rule
            if rule.order == Int(Int32.min) { rule.order = (rules.map(\.order).max() ?? 0) + 1 }
            rules.append(rule)
        }
        persist()
    }

    public func delete(_ ids: Set<Int64>) {
        rules.removeAll { ids.contains($0.id) }
        persist()
    }

    public func setEnabled(_ enabled: Bool, for ids: Set<Int64>) {
        for index in rules.indices where ids.contains(rules[index].id) {
            rules[index].isEnabled = enabled
        }
        persist()
    }

    public func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        rules.moveElements(fromOffsets: offsets, toOffset: destination)
        for index in rules.indices {
            rules[index].order = index
        }
        persist()
    }

    public func export(_ ids: Set<Int64>? = nil) throws -> Data {
        let items = ids.map { set in rules.filter { set.contains($0.id) } } ?? rules
        return try SourceImport.export(items)
    }

    public func flush() {
        store.flush()
    }

    private func persist() {
        let snapshot = rules
        store.update { $0 = snapshot }
    }
}

extension ReplaceRule {
    static func splitScope(_ value: String) -> [String] {
        value.components(separatedBy: CharacterSet(charactersIn: ",;，；"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
