import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// ⭐⭐⭐⭐⭐ **内存水位计量**（2026-10-26 jetsam 6.8GB 实证）
///
/// ⚠️⚠️⚠️ **真机事故（2026-10-26 崩溃日志实证）**：
///   jetsam 记录里 `QingYue` **单进程** `rpages = 425984` ⇒ ×16KB = **6.8GB**
///   ⇒ **被系统内存杀**（jetsam，不是崩溃）⇒ 现象 =「闪退」+ **没有 .ips 崩溃日志** ⭐⭐⭐
///   ⇒ 同批证据「本小时写盘」只有 142 B ⇒ **磁盘写入那条线彻底排除** ⭐⭐⭐
///
/// ⭐⭐⭐⭐⭐ **本计量器存在的三个理由**：
///   ① **看得见**：自检面板显示「当前占用 / 峰值 / 限额 / 自动清理次数」
///      ⇒ 下次再被杀 ⇒ 一眼看出「涨到多少被杀」⇒ **不用再猜** ⭐⭐⭐
///   ② **保得住**：占用超限 ⇒ **主动清空引擎会话（= 重建 JS context）**
///      ⇒ 抢在 jetsam 之前自救（**宁可丢一次会话，也别整个 App 死掉**）⭐⭐⭐
///   ③ **记得住**：记录自动清理的次数 + 清理前后水位 ⇒ 出事能翻日志 ⭐⭐⭐
///
/// ⚠️⚠️⚠️ **build263 补的第四条（最关键的一条）**：
///   jetsam 杀进程 ⇒ **内存里的峰值/日志一起没了** ⇒ 崩了之后再打开面板
///   ⇒ **看不到「被杀前涨到多少」** ⇒ 白查一轮 ⭐⭐⭐
///   ⇒ ⇒ 所以峰值 + 采样（**带 op 名**）必须**落盘** ⇒ 跨启动保留 ⭐⭐⭐
///   ⇒ ⇒ 这样「是哪个 op 把内存撑上去的」就能**回看**（最后一个采样带 op 名）⭐⭐⭐
///
/// ⚠️ **量的是 `phys_footprint`**（不是 `resident_size`）
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

    /// ⭐⭐⭐ **一次 op 的峰值**（op 开始时快照，op 结束时结算）
    ///
    /// ⚠️ 为什么要有：**op 内部爆掉时，op 结束后的采样可能已经晚了**（App 已被 jetsam 杀）
    ///   ⇒ 必须在 op **期间**采样 ⇒ 才知道是哪个 op ⭐⭐⭐
    private static var watchTimer: DispatchSourceTimer?
    private static var watchOp: String = ""
    private static var watchSource: String = ""
    private static var watchPeakBytes: Int = 0

    /// ⭐⭐⭐ **op 开始 ⇒ 起后台采样器**（每 250ms 采一次；超限立刻落盘）
    static func startWatch(op: String, source: String) {
        lock.lock(); defer { lock.unlock() }
        stopWatchLocked()
        watchOp = op
        watchSource = source
        watchPeakBytes = 0
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        // ⚠️ `MemoryMeter` 是 enum（不是类）⇒ 不能 `[weak self]` ⇒ 直接静态调 ⭐⭐⭐
        t.setEventHandler {
            MemoryMeter.watchTick()
        }
        watchTimer = t
        t.resume()
    }

    /// ⭐⭐⭐ **op 结束 ⇒ 停采样器**
    static func stopWatch() {
        lock.lock(); defer { lock.unlock() }
        stopWatchLocked()
    }

    private static func stopWatchLocked() {
        watchTimer?.cancel()
        watchTimer = nil
    }

    /// ⭐ 采样器的一次心跳：超限 ⇒ **立刻落盘**（不等 op 结束）
    private static func watchTick() {
        let bytes = footprintBytes()
        lock.lock()
        watchPeakBytes = max(watchPeakBytes, bytes)
        if bytes > peakBytes { peakBytes = bytes }
        let over = bytes > 0 && bytes >= autoResetThresholdMB * 1024 * 1024
        let op = watchOp
        let src = watchSource
        lock.unlock()
        guard over else { return }
        noteTrip(op: op, source: src, peakMB: bytes / (1024 * 1024))
    }

    /// ⭐⭐⭐ **记一次「内存超限」并落盘**（⇒ 下次启动能熔断这个源）
    static func noteTrip(op: String, source: String, peakMB: Int) {
        lock.lock(); defer { lock.unlock() }
        let t = Trip(at: Date().timeIntervalSince1970, op: op, source: source, peakMB: peakMB)
        trips.removeAll { $0.source == source }     // 同一个源只留最新一条
        trips.append(t)
        if trips.count > 20 { trips.removeFirst(trips.count - 20) }
        writeTripsLocked()
    }

    /// ⭐⭐⭐ **这个源是不是已经「内存炸过」**（⇒ 熔断，别再跑）
    static func isTripped(source: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        loadTripsLocked()
        return trips.contains { $0.source == source }
    }

    /// ⭐ 熔断清单（面板显示）
    static var tripsText: String {
        lock.lock(); defer { lock.unlock() }
        loadTripsLocked()
        if trips.isEmpty { return "（无）" }
        return trips.map { t in
            let f = DateFormatter()
            f.dateFormat = "MM-dd HH:mm"
            let src = t.source.isEmpty ? "?" : String(t.source.suffix(28))
            return "\(f.string(from: Date(timeIntervalSince1970: t.at))) · \(src) · op=\(t.op) · 峰值 \(t.peakMB) MB"
        }.joined(separator: "\n")
    }

    /// ⭐ **手动解除熔断**（用户想再试一次时）
    static func clearTrips() {
        lock.lock(); defer { lock.unlock() }
        trips.removeAll()
        writeTripsLocked()
    }

    private static var trips: [Trip] = []
    private static var tripsLoaded = false

    private static func loadTripsLocked() {
        guard !tripsLoaded else { return }
        tripsLoaded = true
        guard let url = storeURL else { return }
        // 熔断存在**独立文件** ⇒ 不跟内存档案（会被 op 覆写）互相干扰
        let tripURL = url.deletingLastPathComponent()
            .appendingPathComponent("memory-trips.json")
        guard let data = try? Data(contentsOf: tripURL),
              let arr = try? JSONDecoder().decode([Trip].self, from: data) else { return }
        trips = arr
    }

    private static func writeTripsLocked() {
        guard let url = storeURL else { return }
        let tripURL = url.deletingLastPathComponent()
            .appendingPathComponent("memory-trips.json")
        if let data = try? JSONEncoder().encode(trips) {
            try? data.write(to: tripURL)
        }
    }

    // MARK: - 落盘档案（jetsam 杀进程 ⇒ 内存里的证据全没 ⇒ 必须落盘）

    /// ⭐⭐⭐ **一次「内存超限」的记录**（源 + op + 峰值）—— **崩了也不能丢**
    ///
    /// ⚠️⚠️ **为什么必须落盘**：jetsam 杀进程 ⇒ 内存里的东西全没
    ///   ⇒ 下次启动**不知道**哪个源炸过 ⇒ 还会再炸一次 ⇒ **反复闪退** ⭐⭐⭐
    ///   ⇒ 落盘 ⇒ 下次启动读到 ⇒ **直接熔断这个源** ⇒ **不再闪退** ⭐⭐⭐
    struct Trip: Codable {
        var at: Double = 0
        var op: String = ""
        var source: String = ""
        var peakMB: Int = 0
    }

    /// ⭐ 一次采样（时间 + MB + 当时的 op 名）
    struct Sample: Codable, Equatable {
        var t: Double = 0
        var mb: Int = 0
        var op: String = ""
    }

    /// ⭐ 落盘的档案（**上一次进程**留下的）
    struct Archive: Codable {
        var peakMB: Int = 0
        var endMB: Int = 0
        var updatedAt: Double = 0
        var autoResetCount: Int = 0
        var samples: [Sample] = []
    }

    private static var archiveLoaded = false
    /// ⭐ **上次进程**（可能就是被杀的那次）留下的档案
    private static var lastArchive = Archive()
    /// ⭐ **本次进程**的采样（落盘时写这个 ⇒ 文件永远描述「当前或上一个进程」）
    private static var sessionSamples: [Sample] = []
    /// ⭐ 落盘位置（由 App 侧注入 ⇒ 本文件不依赖 AppPaths ⇒ 沙盒能单独编）
    private static var storeURL: URL?
    private static var lastPersistAt: Date = .distantPast

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

    /// ⭐⭐⭐ **注入落盘位置**（App 启动时调一次；不注入 ⇒ 只在内存里记，不落盘）
    static func configure(storeURL url: URL?) {
        lock.lock(); defer { lock.unlock() }
        if storeURL == nil { storeURL = url }
        ensureArchiveLoadedLocked()
    }

    /// ⭐⭐⭐ **把采样落盘**（这样被 jetsam 杀掉也不丢证据）
    ///
    /// ⚠️ **写盘量**：一个几 KB 的文件，每次 op 一写 ⇒ 相对 iOS 的 diskwrites 限额可忽略 ⭐⭐⭐
    private static func writeArchiveLocked() {
        guard let url = storeURL else { return }
        let now = Date()
        lastPersistAt = now
        // ⭐ 文件里写的**永远是「当前这个进程」的会话**（不是合并）⇒
        //   下次启动读到的就是「上一个进程（可能被杀的那次）」⇒ 不会串台 ⭐⭐⭐
        let a = Archive(peakMB: peakBytes / (1024 * 1024),
                        endMB: lastBytes / (1024 * 1024),
                        updatedAt: now.timeIntervalSince1970,
                        autoResetCount: resetCount,
                        samples: sessionSamples)
        // ⚠️ 用「不 atomic」的写法（同 App 其它落盘）⇒ 不额外写临时文件
        if let data = try? JSONEncoder().encode(a) {
            try? data.write(to: url)
        }
    }

    /// ⭐ 首次读档案（把**上一个进程**的记录读进来）
    private static func ensureArchiveLoadedLocked() {
        guard !archiveLoaded else { return }
        archiveLoaded = true
        guard let url = storeURL,
              let data = try? Data(contentsOf: url),
              let a = try? JSONDecoder().decode(Archive.self, from: data) else { return }
        lastArchive = a
    }

    // MARK: - 采样

    /// ⭐⭐⭐ **纯测量**（不记状态）
    static func measure() -> Int { footprintBytes() }

    /// ⭐⭐⭐ **记一次采样 + 落盘**（op 名带上 ⇒ 被 jetsam 杀掉也能定位是哪个 op）
    static func note(bytes: Int, op: String) {
        lock.lock(); defer { lock.unlock() }
        ensureArchiveLoadedLocked()
        lastBytes = bytes
        if bytes > peakBytes { peakBytes = bytes }
        sessionSamples.append(Sample(t: Date().timeIntervalSince1970,
                                     mb: bytes / (1024 * 1024), op: op))
        if sessionSamples.count > 24 { sessionSamples.removeFirst(sessionSamples.count - 24) }
        writeArchiveLocked()
    }

    /// ⭐⭐⭐ 采样当前占用（bytes）⇒ 同时刷新峰值 + 落盘
    @discardableResult
    static func sample(op: String = "") -> Int {
        let bytes = footprintBytes()
        note(bytes: bytes, op: op)
        return bytes
    }

    /// ⭐⭐⭐ **纯逻辑入口**（沙盒可测）：记一次采样 ⇒ 返回「是否已超限」
    ///
    /// ⭐ 为什么把逻辑单独拆出来：`footprintBytes()` 只有 iOS 上才有意义
    ///   ⇒ 沙盒（Linux）里要能**真跑**这套阈值/峰值逻辑 ⇒ 就不能把它埋在平台代码里 ⭐⭐⭐
    @discardableResult
    static func record(bytes: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
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

    /// ⭐⭐⭐⭐⭐ **上次进程（可能就是被杀的那次）的档案**（build263）
    ///
    /// ⚠️ jetsam 杀进程 ⇒ 内存里的东西全没 ⇒ **这一行是唯一能回看「被杀前」的证据** ⭐⭐⭐
    static var lastSessionText: String {
        lock.lock(); defer { lock.unlock() }
        ensureArchiveLoadedLocked()
        let a = lastArchive
        guard a.updatedAt > 0 else { return "上次会话：—（还没有记录）" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        let when = f.string(from: Date(timeIntervalSince1970: a.updatedAt))
        var s = "上次会话（\(when)）：峰值 \(a.peakMB) MB"
        if let last = a.samples.last {
            let t = DateFormatter()
            t.dateFormat = "HH:mm:ss"
            s += " · 最后采样 \(t.string(from: Date(timeIntervalSince1970: last.t)))"
            s += " op=\(last.op.isEmpty ? "—" : last.op) \(last.mb) MB"
        }
        if a.autoResetCount > 0 { s += " · 自动清理 \(a.autoResetCount) 次" }
        return s
    }

    /// ⭐⭐⭐ **采样时间线**（最近 N 条，带 op 名）—— 崩了之后回看能定位「哪个 op 撑的」
    static func timelineText(_ limit: Int = 8) -> String {
        lock.lock(); defer { lock.unlock() }
        ensureArchiveLoadedLocked()
        let rows = lastArchive.samples.suffix(limit).map { s -> String in
            let t = DateFormatter()
            t.dateFormat = "HH:mm:ss"
            let op = s.op.isEmpty ? "—" : s.op
            return "\(t.string(from: Date(timeIntervalSince1970: s.t)))  op=\(op)  \(s.mb) MB"
        }
        return rows.joined(separator: "\n")
    }
}
