import Foundation

/// ⭐⭐⭐ **源字典缓存**（把 158KB 的源只编码 + 解析**一次**，而且**不在主线程上**）
///
/// ⚠️⚠️ **这是真机「进大灰狼发现页就死机」的真凶**（2026-10-24，崩溃日志 `0x8BADF00D` 实证）：
///   引擎的每个 op 都要吃一份「源的字典」（`[String: Any]`）。
///   以前 `SourceService.call()` **每次 op** 都做：
///     ① `AppEncoder.encode(source)` —— 把整个源编码成 JSON（**大灰狼 158KB**）
///     ② `JSONSerialization.jsonObject(with:)` —— **Foundation 的 JSON 解析器**
///        （会建一大堆 NSString/NSDictionary/NSArray ⇒ 内存翻好几倍）
///   ⇒ 而 `effectiveVars(for:)` 里**还要再来一遍**（它自己也编码+解析一次）
///   ⇒ **新旧引擎都死机**：两条路共用 `call()` 里这一段！⇒ 只换引擎没用 ⭐⭐⭐
///
/// ⇒ **崩溃链**（真机崩溃日志逐帧对上）：
///   · 后台线程：`LegadoEngineBackend.invoke` → `seedVars` → `Foundation _NSJSONReader parseData`
///     （**持有 malloc 锁**）
///   · 主线程：`_xzm_malloc_tc`（**拿不到 malloc 锁**）⇒ UI 全冻 ⇒ iOS watchdog 杀进程
///     （`0x8BADF00D` = "Bad Coffee" = 卡死 5 秒没响应）
///
/// ⇒ **两条修**：
///   ① **同一个源只算一次**（缓存）⇒ 每个 op 的分配降到 1/N
///   ② ⭐⭐⭐ **慢路径离开主线程** ⇒ 第一次进大灰狼发现页时，
///      **主线程不再做 158KB 的编码+解析** ⇒ 不会卡 ⇒ 不会死机 ⭐⭐⭐
enum SourceDictCache {
    private static let lock = NSLock()
    /// key = bookSourceUrl；stamp = 缓存版本（源一变就 +1 ⇒ 旧的自动作废）
    private static var cache: [String: (stamp: Int, dict: [String: Any])] = [:]
    private static var stamp: Int = 0
    private static var encodeCount: Int = 0

    /// **源变了**（导入 / 覆盖 / 删除）⇒ 清缓存
    static func invalidate() {
        lock.lock()
        stamp &+= 1
        cache.removeAll()
        lock.unlock()
    }

    /// **编码 + 解析的次数**（门禁用：证明「只算一次」而不是「每个 op 算一次」）
    static var encodes: Int {
        lock.lock(); defer { lock.unlock() }
        return encodeCount
    }

    // MARK: - 锁只出现在**同步**函数里（⭐ Swift 6：async 上下文里不许 `lock.lock()`）

    private static func cachedDict(for key: String) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        guard let hit = cache[key], hit.stamp == stamp else { return nil }
        return hit.dict
    }

    private static func store(_ obj: [String: Any], for key: String) {
        lock.lock(); defer { lock.unlock() }
        encodeCount += 1
        cache[key] = (stamp, obj)
        // 别无限涨（换很多源会攒一堆大字典）
        if cache.count > 24 {
            for k in cache.keys.sorted().prefix(cache.count / 2) { cache.removeValue(forKey: k) }
        }
    }

    // MARK: - 对外

    /// 源 ⇒ 引擎要的字典（**命中缓存就同步返回；没命中去后台算**）
    ///
    /// ⭐⭐⭐ **慢路径必须在后台**（2026-10-24 真机）：
    ///   以前同步算 ⇒ **主线程**上编码+Foundation 解析 158KB
    ///   ⇒ **主线程卡住** ⇒ iOS watchdog 5 秒就杀进程 ⇒ **进大灰狼发现页就死机** ⭐⭐⭐
    ///   ⇒ **新旧引擎都一样**（两条路共用 `call()` 里这段）
    static func dict(for source: BookSource) async -> [String: Any] {
        let key = source.bookSourceUrl
        if let hit = cachedDict(for: key) { return hit }
        // ⭐ 慢路径：**后台队列**算 ⇒ 主线程只等结果，不卡 ⭐
        let obj = await withCheckedContinuation { (cont: CheckedContinuation<[String: Any], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: Self.encodeAndParse(source))
            }
        }
        store(obj, for: key)
        return obj
    }

    /// 同步版（**只在明确不在主线程时用**；门禁/测试用）
    static func dictSync(for source: BookSource) -> [String: Any] {
        let key = source.bookSourceUrl
        if let hit = cachedDict(for: key) { return hit }
        let obj = encodeAndParse(source)
        store(obj, for: key)
        return obj
    }

    /// 编码 + Foundation 解析（**只在后台跑**）
    private static func encodeAndParse(_ source: BookSource) -> [String: Any] {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]   // 与 AppEncoder 一致
        guard let data = try? enc.encode(source),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }
}
