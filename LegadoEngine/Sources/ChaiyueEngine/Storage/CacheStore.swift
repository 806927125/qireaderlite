import Foundation

/// 对应 Legado `CacheManager`：带过期时间的持久缓存 + 进程内内存缓存
public final class CacheStore: @unchecked Sendable {
    // ⭐⭐⭐ **移植补丁（2026-11-21）**：`private` → internal ⇒ 让 `Compat/LegadoPublicAPI.swift`
    //   的扩展能枚举键（导出全部书源变量用）⭐⭐⭐
    let store: KeyValueStore
    private var memory: [String: Any] = [:]
    private let lock = NSLock()
    private static let prefix = "cache_"

    public init(store: KeyValueStore) {
        self.store = store
    }

    /// saveTime 单位为秒，0 表示永久
    public func put(_ key: String, _ value: String, saveTime: Int = 0) {
        let deadline = saveTime > 0 ? Int64(Date().timeIntervalSince1970 * 1000) + Int64(saveTime) * 1000 : 0
        store.set("\(deadline)\u{1}\(value)", forKey: Self.prefix + key)
        lock.withLock { memory[key] = value }
    }

    public func get(_ key: String) -> String? {
        if let v = lock.withLock({ memory[key] as? String }) { return v }
        guard let raw = store.string(forKey: Self.prefix + key) else { return nil }
        guard let sep = raw.firstIndex(of: "\u{1}") else { return raw }
        let deadline = Int64(raw[..<sep]) ?? 0
        if deadline > 0, deadline < Int64(Date().timeIntervalSince1970 * 1000) {
            store.set(nil, forKey: Self.prefix + key)
            return nil
        }
        let value = String(raw[raw.index(after: sep)...])
        lock.withLock { memory[key] = value }
        return value
    }

    public func delete(_ key: String) {
        store.set(nil, forKey: Self.prefix + key)
        lock.withLock { _ = memory.removeValue(forKey: key) }
    }

    public func putMemory(_ key: String, _ value: Any?) {
        lock.withLock { memory[key] = value }
    }

    public func getFromMemory(_ key: String) -> Any? {
        lock.withLock { memory[key] }
    }

    public func deleteMemory(_ key: String) {
        lock.withLock { _ = memory.removeValue(forKey: key) }
    }
}
