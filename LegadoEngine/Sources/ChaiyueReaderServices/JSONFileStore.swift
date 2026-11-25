import Foundation

/// JSON 文件存储：内存值为准，修改后防抖写盘。
/// 写入时先把旧文件复制为 `.bak`，再原子替换主文件；主文件损坏时从备份恢复。
public final class JSONFileStore<Value: Codable & Sendable>: @unchecked Sendable {
    public let url: URL
    private let backupURL: URL
    private let delay: TimeInterval
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var value: Value
    private var dirty = false
    private var scheduled = false

    private static var ioQueue: DispatchQueue { JSONFileStoreQueue.shared }

    public init(url: URL, delay: TimeInterval = 0.5, defaultValue: () -> Value) {
        self.url = url
        self.backupURL = url.appendingPathExtension("bak")
        self.delay = delay
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        value = Self.load(url) ?? Self.load(backupURL) ?? defaultValue()
    }

    private static func load(_ url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    public var current: Value {
        lock.withLock { value }
    }

    @discardableResult
    public func update<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        let result = try lock.withLock {
            let result = try body(&value)
            dirty = true
            return result
        }
        scheduleSave()
        return result
    }

    private func scheduleSave() {
        let needsSchedule = lock.withLock {
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        guard needsSchedule else { return }
        Self.ioQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.flush()
        }
    }

    /// 立即写盘（进入后台、退出前调用）
    public func flush() {
        writeLock.lock()
        defer { writeLock.unlock() }
        let snapshot: Value? = lock.withLock {
            scheduled = false
            guard dirty else { return nil }
            dirty = false
            return value
        }
        guard let snapshot else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let data = try encoder.encode(snapshot)
            let fm = FileManager.default
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: backupURL)
                try? fm.copyItem(at: url, to: backupURL)
            }
            try data.write(to: url, options: .atomic)
        } catch {
            lock.withLock { dirty = true }
        }
    }
}

private enum JSONFileStoreQueue {
    static let shared = DispatchQueue(label: "ReaderServices.JSONFileStore", qos: .utility)
}
