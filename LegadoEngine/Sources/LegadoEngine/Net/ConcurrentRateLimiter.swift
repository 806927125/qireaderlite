import Foundation

/// 书源并发限速。concurrentRate："500" = 每次间隔 500ms；"2/1000" = 1000ms 内最多 2 次。
public final class ConcurrentRateLimiter {
    private final class Record {
        var lastStart: Int64 = 0
        var windowStart: Int64 = 0
        var windowCount: Int = 0
    }
    private static let lock = NSLock()
    private static var records: [String: Record] = [:]

    private let key: String?
    private let rate: String?

    public init(_ source: BookSource?) {
        key = source?.bookSourceUrl
        rate = source?.concurrentRate
    }

    private func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    public func wait() async {
        guard let key, let rate, !rate.isEmpty else { return }
        var delayMs: Int64 = 0
        Self.lock.lock()
        let rec = Self.records[key] ?? Record()
        Self.records[key] = rec
        let t = now()
        if let slash = rate.firstIndex(of: "/") {
            let count = Int(rate[..<slash]) ?? 1
            let window = Int64(rate[rate.index(after: slash)...]) ?? 1000
            if t - rec.windowStart >= window {
                rec.windowStart = t; rec.windowCount = 0
            }
            if rec.windowCount >= count {
                delayMs = window - (t - rec.windowStart)
                rec.windowStart = t + delayMs
                rec.windowCount = 1
            } else {
                rec.windowCount += 1
            }
        } else if let interval = Int64(rate) {
            let due = rec.lastStart + interval
            if t < due { delayMs = due - t }
            rec.lastStart = t + delayMs
        }
        Self.lock.unlock()
        if delayMs > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
        }
    }
}