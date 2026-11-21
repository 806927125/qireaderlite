import Foundation

/// 书源运行时使用的字符串键值存储（缓存、Cookie、书源变量、登录信息）
public protocol KeyValueStore: AnyObject, Sendable {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
    func keys(withPrefix prefix: String) -> [String]
}

public final class MemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    private var storage: [String: String]
    private let lock = NSLock()

    public init(_ initial: [String: String] = [:]) {
        storage = initial
    }

    public func string(forKey key: String) -> String? {
        lock.withLock { storage[key] }
    }

    public func set(_ value: String?, forKey key: String) {
        lock.withLock { storage[key] = value }
    }

    public func keys(withPrefix prefix: String) -> [String] {
        lock.withLock { storage.keys.filter { $0.hasPrefix(prefix) } }
    }
}

/// 以 JSON 文件持久化的键值存储；写入会合并后延迟落盘
public final class FileKeyValueStore: KeyValueStore, @unchecked Sendable {
    public let fileURL: URL
    private var storage: [String: String] = [:]
    private var saveScheduled = false
    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "RuleEngine.FileKeyValueStore", qos: .utility)

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let map = try? JSONDecoder().decode([String: String].self, from: data) {
            storage = map
        }
    }

    public func string(forKey key: String) -> String? {
        lock.withLock { storage[key] }
    }

    public func set(_ value: String?, forKey key: String) {
        let schedule: Bool = lock.withLock {
            storage[key] = value
            if saveScheduled { return false }
            saveScheduled = true
            return true
        }
        if schedule {
            ioQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.flush() }
        }
    }

    public func keys(withPrefix prefix: String) -> [String] {
        lock.withLock { storage.keys.filter { $0.hasPrefix(prefix) } }
    }

    /// 立即写入磁盘
    public func flush() {
        let snapshot: [String: String] = lock.withLock {
            saveScheduled = false
            return storage
        }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
