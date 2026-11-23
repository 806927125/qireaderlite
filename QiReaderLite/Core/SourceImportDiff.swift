import Foundation

/// ⭐⭐⭐⭐⭐ **书源导入的「有没有变化」判定**（2026-11-23 真机反馈）
///
/// ⚠️⚠️ **用户原话**：「导入书源时候**同个要看有没有变化**，**有变化就是要更新书源**，
///   现在是**有书源的情况下导不进去**」⭐⭐⭐
///
/// ⚠️⭐⭐⭐ **真因（两个，缺一不可）** ⭐⭐⭐：
///   ① **提示误导**：`importSources` 返回的是**「新增条数」**
///      ⇒ 已有同 URL 书源时返回 **0** ⇒ Toast 显示「**导入 0 个书源**」
///      ⇒ **但源其实已经被替换了**（`index[url] = s`）⇒ ⇒ **用户以为没导进去** ⭐⭐⭐
///   ② **判不出变化**：`BookSourceParser.parse` 里就 **`archiveRaw` 覆盖了存档**
///      ⇒ ⇒ 「上次导入的原始 JSON」被**本次的内容覆盖**⇒ ⇒ **没法比** ⇒ ⇒ **必须「先比后存」** ⭐⭐⭐
///
/// ⭐⭐⭐ **本文件刻意只依赖 Foundation** ⇒ ⇒ **Linux 沙盒能 swiftc 真编真跑**
/// ⇒ ⇒ 「有没有变化」的判定**当天就能验**，不用等 CI ⭐⭐⭐
///
/// ⭐⭐⭐ **判据用「规范化 JSON」而不是 `lastUpdateTime`** ⭐⭐⭐
///   ⇒ 站方改内容**常常不改 `lastUpdateTime`** ⇒ ⇒ 只比时间 ⇒ **改内容也会被误判成「没变」**
///   ⇒ ⇒ **这正是用户说的「有变化就要更新」要解决的** ⭐⭐⭐
enum SourceImportDiff {

    /// 把原始 JSON **规范化**（键排序 ⇒ 键序无关；空白被 JSONSerialization 吃掉）
    /// - Returns: 规范化后的字节；不可序列化时返回 nil
    static func normalized(_ dict: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(dict) else { return nil }
        // ⚠️ `.sortedKeys` 是 Foundation 内置 ⇒ **键序无关** ⭐⭐⭐
        return try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    }

    /// ⭐⭐⭐ **「有没有变化」** —— 核心判据
    /// - Parameters:
    ///   - oldRaw: **上次导入时存档的**原始 JSON（没有 ⇒ nil）
    ///   - newRaw: 本次导入的原始 JSON
    /// - Returns: `true` = **有变化**（⇒ 该更新）
    static func hasChanged(oldRaw: [String: Any]?, newRaw: [String: Any]) -> Bool {
        // ⚠️⚠️ **没有旧存档 ⇒ 判「有变化」** ⭐⭐⭐
        //   ⇒ 场景：老版本导入的源（那时还没存档机制）⇒ 用户现在导一份新的 ⇒ **必须更新** ⭐⭐⭐
        guard let oldRaw else { return true }
        guard let a = normalized(oldRaw), let b = normalized(newRaw) else {
            // ⚠️ 规范化失败 ⇒ **保守判「有变化」** ⇒ 更新（宁可多更新，别漏更新）⭐⭐⭐
            return true
        }
        return a != b
    }

    /// ⭐⭐⭐⭐⭐ **导入决策**（**纯逻辑 ⇒ 沙盒能真编真跑** ⇒ 门禁能真验**）⭐⭐⭐
    ///
    /// ⚠️⚠️ **为什么把编排也搬到这里**（2026-11-23）⭐⭐⭐：
    ///   `Store.swift` **import SwiftUI** ⇒ **Linux 沙盒编不到** ⇒
    ///   ⇒ 编排逻辑放那儿 ⇒ **沙盒门禁永远验不到它** ⇒ ⇒ **等于没有门禁** ⭐⭐⭐
    ///   ⇒ ⇒ 把「逐源判定」整个搬进**纯 Foundation 的本文件** ⇒ ⇒ 门禁能**真跑真验** ⭐⭐⭐
    struct Plan {
        var added: [BookSource] = []
        var updated: [BookSource] = []
        var unchanged: [BookSource] = []
        var stats: Stats {
            Stats(added: added.count, updated: updated.count, unchanged: unchanged.count)
        }
    }

    /// ⭐⭐⭐⭐⭐ **逐源判定：新增 / 更新 / 未变**（**核心判据**）
    ///
    /// - Parameters:
    ///   - existing: 现有的源（按 `bookSourceUrl` 索引）
    ///   - incoming: 本次导入的源 + 它的**原始 JSON**
    ///   - oldRaw: 取「上次导入时存档的原始 JSON」的闭包（`nil` = 没有存档）
    /// - Returns: 决策（**「未变」的源不要覆盖** ⇒ 保留用户在 App 里的改动）⭐⭐⭐
    static func plan(existing: [BookSource],
                     incoming: [(source: BookSource, raw: [String: Any]?)],
                     oldRaw: (String) -> [String: Any]?) -> Plan {
        var index = Dictionary(existing.map { ($0.bookSourceUrl, $0) }, uniquingKeysWith: { _, last in last })
        var out = Plan()
        for item in incoming {
            let s = item.source
            guard !s.bookSourceUrl.isEmpty else { continue }
            let isNew = index[s.bookSourceUrl] == nil
            if isNew {
                out.added.append(s)
                index[s.bookSourceUrl] = s
                continue
            }
            // ⚠️ 拿不到新原始 JSON ⇒ 保守判「有变化」⇒ 更新（宁可多更新，别漏更新）⭐⭐⭐
            let changed: Bool
            if let newRaw = item.raw {
                changed = hasChanged(oldRaw: oldRaw(s.bookSourceUrl), newRaw: newRaw)
            } else {
                changed = true
            }
            if changed {
                // ⭐⭐⭐ **保留用户的「启用/停用」偏好** ⇒ 导入内容更新不该把用户手动禁用的源又打开 ⭐⭐⭐
                var next = s
                if let old = index[s.bookSourceUrl] { next.enabled = old.enabled }
                out.updated.append(next)
                index[s.bookSourceUrl] = next
            } else {
                // ⭐⭐⭐⭐⭐ **未变 ⇒ 不动它**（保留用户改动）⭐⭐⭐
                //   ⇒ 这里装**【旧的那份】**（不是新来的那份）⇒
                //   ⇒ **「最终状态」= 旧的** ⇒ ⇒ 门禁能直接断言「有没有被覆盖」⭐⭐⭐
                //   ⚠️ 之前装「新来的那份」⇒ ⇒ 断言测不出「未变时到底覆盖没覆盖」⇒ **假绿** ⭐⭐⭐
                out.unchanged.append(index[s.bookSourceUrl] ?? s)
            }
        }
        return out
    }

    /// ⭐⭐⭐ **导入结果统计**（给 UI 说得清楚「新增/更新/未变」）
    struct Stats: Equatable {
        var added = 0
        var updated = 0
        var unchanged = 0
        init() {}
        init(added: Int, updated: Int, unchanged: Int) {
            self.added = added; self.updated = updated; self.unchanged = unchanged
        }
        /// 一句话总结（给 Toast 用）
        var summary: String {
            var parts: [String] = []
            if added > 0 { parts.append("新增 \(added)") }
            if updated > 0 { parts.append("更新 \(updated)") }
            if unchanged > 0 { parts.append("未变 \(unchanged)") }
            return parts.isEmpty ? "没有可导入的书源" : parts.joined(separator: "，")
        }
    }
}
