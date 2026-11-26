// ⭐⭐⭐⭐⭐ **平台条件编译补丁**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//   · Linux 沙盒没有 CryptoKit ⇒ 改用 swift-crypto 的 `Crypto`（同名 API）⭐⭐⭐
//   · 沿用本仓库 `ChaiyueEngine/Crypto/Digests.swift` 的既有做法 ⭐⭐⭐
#if canImport(Crypto)
import Crypto
#elseif canImport(CryptoKit)
import CryptoKit
#endif
import Foundation

enum Hashing {
    static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// 导入合并结果
public struct ImportSummary: Sendable, Equatable {
    public var added = 0
    public var updated = 0
    public var unchanged = 0

    public init(added: Int = 0, updated: Int = 0, unchanged: Int = 0) {
        self.added = added
        self.updated = updated
        self.unchanged = unchanged
    }

    public var total: Int { added + updated + unchanged }

    public var text: String {
        var parts = ["新增 \(added) 个"]
        if updated > 0 { parts.append("更新 \(updated) 个") }
        if unchanged > 0 { parts.append("未变化 \(unchanged) 个") }
        return parts.joined(separator: "，")
    }
}

extension Array {
    /// 与 SwiftUI 的 `move(fromOffsets:toOffset:)` 语义一致，避免服务层依赖 SwiftUI
    mutating func moveElements(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { self[$0] }
        let insertAt = destination - source.filter { $0 < destination }.count
        for index in source.sorted(by: >) {
            remove(at: index)
        }
        insert(contentsOf: moving, at: Swift.max(0, Swift.min(insertAt, count)))
    }
}
