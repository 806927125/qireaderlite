import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// ⭐⭐⭐ **内存水位计量**（jetsam 判杀用的同一个口径 · phys_footprint）
///
/// ⭐⭐⭐ **2026-10-26：内存熔断那套已移除**（用户明确：「内存熔断啥的就不要了，老引擎又不会闪退」）
///   ⇒ 移除：op 期间的高频采样器 / 「这个源炸过」的落盘清单 / 超限自动清会话 / 面板的熔断清单
///   ⇒ **保留**：当前值与峰值（面板上给用户看一眼 ⇒ 便宜、无副作用）
///   ⇒ **防撑爆靠的是「闸门」不是「熔断」**：
///      · 变量表回传封顶 256KB · 单响应体封顶 32MB · HTTP 缓存按字节封顶 48MB
///      · 桥接层脚本 ≤ 8MB / 返回体 ≤ 32MB
///      · 而**根因**是：老引擎的规则求值住在 **WKWebView 独立进程** ⇒ App 进程压根不碰站方数据 ⭐⭐⭐
enum MemoryMeter {

    private static let lock = NSLock()
    private static var lastBytes: Int = 0
    private static var peakBytes: Int = 0

    private static var archiveLoaded = false
    private static var sessionSamples: [Sample] = []
    private static var storeURL: URL?

    struct Sample: Codable, Equatable {
        var t: Double
        var mb: Int
        var op: String
    }

    struct Archive: Codable {
        var peakMB: Int = 0
        var endMB: Int = 0
        var updatedAt: Double = 0
        var samples: [Sample] = []
    }

    static func configure(storeURL url: URL?) {
        lock.lock(); defer { lock.unlock() }
        if storeURL == nil { storeURL = url }
    }

    /// ⭐ 量一次（jetsam 同一口径）
    static func measure() -> Int { footprintBytes() }

    /// ⭐ 记一次采样（面板显示用）
    static func note(bytes: Int, op: String) {
        lock.lock(); defer { lock.unlock() }
        lastBytes = bytes
        if bytes > peakBytes { peakBytes = bytes }
        sessionSamples.append(Sample(t: Date().timeIntervalSince1970,
                                     mb: bytes / (1024 * 1024), op: op))
        if sessionSamples.count > 24 { sessionSamples.removeFirst(sessionSamples.count - 24) }
    }

    @discardableResult
    static func sample(op: String = "") -> Int {
        let bytes = footprintBytes()
        note(bytes: bytes, op: op)
        return bytes
    }

    static func footprintBytes() -> Int {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { r in
                task_info(mach_task_self(), task_flavor_t(TASK_VM_INFO), r, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let footprint = Int(info.phys_footprint)
        if footprint > 0 { return footprint }
        return Int(info.resident_size)
        #else
        return 0
        #endif
    }

    static var currentBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return lastBytes
    }

    static var peakBytesValue: Int {
        lock.lock(); defer { lock.unlock() }
        return peakBytes
    }

    static var currentMB: Int { currentBytes / (1024 * 1024) }
    static var peakMB: Int { peakBytesValue / (1024 * 1024) }
    static var isAvailable: Bool { currentBytes > 0 }

    /// ⭐ 面板上的**内存那一行**（当前 + 峰值；没有熔断/限额/自动清理了 ⇒ 2026-10-26 拆掉）
    static var panelLine: String {
        guard isAvailable else { return "内存：量不到（当作不知道）" }
        return "内存：\(currentMB) MB（峰值 \(peakMB) MB）"
    }
}
