import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// ⭐⭐⭐⭐⭐ **内存水位计量**（2026-10-26 jetsam 6.8GB 实证）
///
/// ⚠️⚠️⚠️ **真机事故（2026-10-26 崩溃日志实证）**：
///   jetsam 记录里 `QingYue` **单进程** `rpages = 425984` ⇒ ×16KB = **6.8GB**
///   ⇒ **被系统内存杀**（jetsam）⇒ 现象 =「闪退」+ **没有 .ips 崩溃日志** ⭐⭐⭐
///   ⇒ 同批证据「本小时写盘」只有 142 B ⇒ **磁盘写入那条线彻底排除** ⭐⭐⭐
///
/// ⭐⭐⭐⭐⭐ **本计量器存在的三个理由**：
///   ① **看得见**：自检面板显示「当前占用 / 峰值 / 限额 / 自动清理次数」
///      ⇒ 下次再被杀 ⇒ 一眼看出「涨到多少被杀」⇒ **不用再猜** ⭐⭐⭐
///   ② **保得住**：占用超限 ⇒ **主动清空引擎会话（= 重建 JS context）**
///      ⇒ 抢在 jetsam 之前自救（**宁可丢一次会话，也别整个 App 死掉**）⭐⭐⭐
///   ③ **记得住**：记录自动清理的次数 + 清理前后水位 ⇒ 出事能翻日志 ⭐⭐⭐
///
/// ⚠️⚠️ **量的是 `phys_footprint`**（不是 `resident_size`）
///   ⇒ **这正是 jetsam 判杀用的量** ⇒ 我们的阈值跟系统同一口径 ⇒ 才作数 ⭐⭐⭐
///
/// ⚠️ **量不到时（返回 0）⇒ 一律当成「不知道」**
///   ⇒ **绝不因为量不到就乱清**（宁可不清，也不能把好会话白丢）⭐⭐⭐
enum MemoryMeter {

    private static let lock = NSLock()
    private static var lastBytes: Int = 0
    private static var peakBytes: Int = 0
    private static var resetCount: Int = 0
    private static var lastResetAt: Date?
    private static var lastResetFromMB: Int = 0
    private static var lastResetToMB: Int = 0

    /// ⭐⭐⭐ **自动清理阈值**（footprint，MB）
    ///
    /// ⚠️ 为什么是 600：
    ///   jetsam 的杀线跟设备内存有关（4GB 机约 1GB，6GB 机约 1.5~2GB）
    ///   ⇒ 600MB **远在杀线之下** ⇒ **我们先清、系统后杀** ⇒ 不丢现场 ⭐⭐⭐
    ///   ⇒ 也远高于正常占用（阅读 App 常态 100~250MB）⇒ 不会误伤 ⭐⭐⭐
    static let autoResetThresholdMB = 600

    /// ⭐ 两次自动清理之间的**最小间隔**（秒）—— 防抖
    ///
    /// ⚠️ 为什么要有：清完还是高 ⇒ 说明累积点**不在引擎会话里**
    ///   ⇒ 再清一百次也没用 ⇒ **别刷屏、别把好会话反复清掉** ⭐⭐⭐
    static let autoResetCooldownSeconds: Double = 60

    // MARK: - 采样

    /// ⭐⭐⭐ 采样当前占用（bytes）⇒ 同时刷新峰值
    @discardableResult
    static func sample() -> Int {
        let bytes = footprintBytes()
        lock.lock()
        defer { lock.unlock() }
        lastBytes = bytes
        if bytes > peakBytes { peakBytes = bytes }
        return bytes
    }

    /// ⭐⭐⭐ **纯逻辑入口**（沙盒可测）：记一次采样 ⇒ 返回「是否已超限」
    ///
    /// ⭐ 为什么把逻辑单独拆出来：`footprintBytes()` 只有 iOS 上才有意义
    ///   ⇒ 沙盒（Linux）里要能**真跑**这套阈值/峰值逻辑 ⇒ 就不能把它埋在平台代码里 ⭐⭐⭐
    @discardableResult
    static func record(bytes: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        lastBytes = bytes
        if bytes > peakBytes { peakBytes = bytes }
        // ⚠️ 量不到（0）⇒ **不算超限**（宁可不清，也不能白丢好会话）
        guard bytes > 0 else { return false }
        return bytes >= autoResetThresholdMB * 1024 * 1024
    }

    /// ⭐⭐⭐ **真实占用**（bytes）—— `phys_footprint`（jetsam 口径）
    ///
    /// ⚠️ 非 Apple 平台（沙盒 Linux）⇒ **返回 0** ⇒ 逻辑照样可测 ⭐⭐⭐
    static func footprintBytes() -> Int {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { r in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), r, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        // ⭐ 优先 `phys_footprint`（jetsam 口径）⇒ 取不到才退到 `resident_size`
        let footprint = Int(info.phys_footprint)
        if footprint > 0 { return footprint }
        return Int(info.resident_size)
        #else
        return 0
        #endif
    }

    // MARK: - 读数

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

    /// ⭐ 是不是「量到了」
    static var isAvailable: Bool { currentBytes > 0 }

    /// ⭐ 自动清理次数
    static var autoResetCount: Int {
        lock.lock(); defer { lock.unlock() }
        return resetCount
    }

    /// ⭐⭐⭐ **记一次自动清理**（含清理前后的水位 ⇒ 事后能判断「清得有没有用」）
    static func noteAutoReset(fromMB: Int, toMB: Int) {
        lock.lock(); defer { lock.unlock() }
        resetCount += 1
        lastResetAt = Date()
        lastResetFromMB = fromMB
        lastResetToMB = toMB
    }

    /// ⭐ 最近一次自动清理的时间（没有 ⇒ 「—」）
    static var lastAutoResetText: String {
        lock.lock(); defer { lock.unlock() }
        guard let at = lastResetAt else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return "\(f.string(from: at))（\(lastResetFromMB)→\(lastResetToMB) MB）"
    }

    /// ⭐ 现在能不能清（**要过冷却期** ⇒ 别反复清）
    static var canAutoResetNow: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let at = lastResetAt else { return true }
        return Date().timeIntervalSince(at) >= autoResetCooldownSeconds
    }

    // MARK: - 文本

    /// ⭐ 人类可读（bytes ⇒ 「123.4 MB」）
    static func text(_ bytes: Int) -> String {
        if bytes <= 0 { return "不可用" }
        if bytes < 1024 * 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    static var currentText: String { text(currentBytes) }
    static var peakText: String { text(peakBytesValue) }

    /// ⭐⭐⭐ **自检面板那一行**
    static var panelLine: String {
        guard isAvailable else {
            return "内存：不可用（本机量不到 phys_footprint）"
        }
        return "内存：\(currentText)（峰值 \(peakText) · 限额 \(autoResetThresholdMB) MB"
            + " · 自动清理 \(autoResetCount) 次 · 上次 \(lastAutoResetText)）"
    }
}
