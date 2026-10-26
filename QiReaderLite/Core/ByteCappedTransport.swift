import Foundation
import LegadoCore

/// ⭐⭐⭐⭐⭐ **按【字节】封顶的 HTTP 缓存**（2026-10-26 jetsam 4.2GB 实证）
///
/// ⚠️⚠️⚠️ **为什么不能按「条数」封顶**：
/// 引擎自带的 `CachedTransport(capacity: 64)` 是**按条数**的 ⇒
/// ⇒ 64 条 × 站方那种「一个响应几 MB~几十 MB」（聚合源把十几个平台的列表 base64 塞一个响应里）
/// ⇒ ⇒ **光缓存就能吃掉几百 MB~GB 级** ⇒ **jetsam 秒杀**（现象 = 闪退 + 没有 .ips）⭐⭐⭐
/// ⇒ 而且这些响应体**还要被 JSON 转义一份、再穿过 JS 桥搬一份** ⇒ 放大好几倍 ⭐⭐⭐
///
/// ⭐ **所以缓存必须按【字节】封顶**（总字节数）⇒ 内存有界 ⇒ 跟源的大小、源的个数都无关 ⭐
/// ⇒ 命中不了只是「多发一次请求」⇒ 功能不受影响（只是慢一点）⭐
final class ByteCappedTransport: HTTPTransport, @unchecked Sendable {

    private let inner: HTTPTransport
    private let ttl: TimeInterval
    private let maxBytes: Int
    private let maxEntries: Int

    private let lock = NSLock()
    private var store: [String: Entry] = [:]
    private var order: [String] = []
    private var bytes = 0

    private struct Entry {
        let response: HTTPResponse
        let at: Date
        let size: Int
    }

    /// - Parameters:
    ///   - maxBytes: **缓存总字节上限**（默认 48MB ⇒ 稳在限额内）
    ///   - maxEntries: 条数上限（兜底：全是小响应时也别无限涨）
    init(inner: HTTPTransport, ttl: TimeInterval = 60,
         maxBytes: Int = 48 * 1024 * 1024, maxEntries: Int = 64) {
        self.inner = inner
        self.ttl = max(0, ttl)
        self.maxBytes = max(1, maxBytes)
        self.maxEntries = max(1, maxEntries)
    }

    /// 缓存当前占用（字节）—— 给自检面板看
    var currentBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return bytes
    }

    func send(_ request: HTTPRequest) throws -> HTTPResponse {
        let key = request.url + "|" + request.method + "|" + (request.headers["Cookie"] ?? "")
        if ttl > 0 {
            lock.lock()
            if let e = store[key], Date().timeIntervalSince(e.at) < ttl {
                if let i = order.firstIndex(of: key) { order.remove(at: i) }
                order.append(key)
                lock.unlock()
                return e.response
            }
            if store[key] != nil { removeLocked(key) }
            lock.unlock()
        }
        let resp = try inner.send(request)
        guard ttl > 0 else { return resp }
        let size = resp.body.count
        // ⭐⭐⭐ **单个响应就超过总上限 ⇒ 干脆不缓存**（缓存它就是自找死）
        guard size <= maxBytes else { return resp }
        lock.lock()
        if store[key] == nil { order.append(key) }
        store[key] = Entry(response: resp, at: Date(), size: size)
        bytes += size
        evictLocked()
        lock.unlock()
        return resp
    }

    /// ⭐ 淘汰到限额内（先进先出）
    private func evictLocked() {
        while bytes > maxBytes || order.count > maxEntries {
            guard let oldest = order.first else { break }
            removeLocked(oldest)
        }
    }

    private func removeLocked(_ key: String) {
        if let e = store.removeValue(forKey: key) { bytes -= e.size }
        if let i = order.firstIndex(of: key) { order.remove(at: i) }
    }
}
