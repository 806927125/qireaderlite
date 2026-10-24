import Foundation

/// ⭐⭐⭐ **源字典缓存**（把 158KB 的源只编码 + 解析**一次**）
///
/// ⚠️⚠️ **这是真机「app 死机」的真凶**（2026-10-24，崩溃日志 `0x8BADF00D` 实证）：
///   引擎的每个 op 都要吃一份「源的字典」（`[String: Any]`）。
///   以前 `SourceService.call()` **每次 op** 都做：
///     ① `AppEncoder.encode(source)` —— 把整个源编码成 JSON（**大灰狼 158KB**）
///     ② `JSONSerialization.jsonObject(with:)` —— **Foundation 的 JSON 解析器**
///        （会建一大堆 NSString/NSDictionary/NSArray ⇒ 内存翻好几倍）
///   ⇒ 而 `effectiveVars(for:)` 里**还要再来一遍**（它自己也编码+解析一次）
///   ⇒ **每次 op 几 MB 的分配** ⇒ 大灰狼一个源就够 ⇒ 别的源小 ⇒ **只有大灰狼出事** ⭐
///
/// ⇒ **崩溃链**（真机崩溃日志逐帧对上）：
///   · 后台线程：`LegadoEngineBackend.invoke` → `seedVars` → `Foundation _NSJSONReader parseData`
///     （**持有 malloc 锁**）
///   · 主线程：`_xzm_malloc_tc`（**拿不到 malloc 锁**）⇒ UI 全冻 ⇒ iOS watchdog 杀进程
///     （`0x8BADF00D` = "Bad Coffee" = 卡死 5 秒没响应）
///
/// ⇒ **修法**：**同一个源只编码+解析一次**，之后每个 op 直接拿缓存 ⭐⭐⭐
///   - 源变了（导入/更新/删除）⇒ `invalidate()` 清一次 ⇒ 不会拿到旧数据
///   - 缓存的字典是**值类型**（Swift Dictionary 的 COW）⇒ 调用方随便改都不会污染缓存
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

    /// 源 ⇒ 引擎要的字典（**命中缓存就不编码**）
    static func dict(for source: BookSource) -> [String: Any] {
        let key = source.bookSourceUrl
        lock.lock()
        let cur = stamp
        if let hit = cache[key], hit.stamp == cur {
            lock.unlock()
            return hit.dict
        }
        lock.unlock()

        // ⭐ 慢路径：编码 + Foundation 解析（**只在缓存 miss 时做一次**）
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]   // 与 AppEncoder 一致
        guard let data = try? enc.encode(source),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }

        lock.lock()
        encodeCount += 1
        cache[key] = (cur, obj)
        // 别无限涨（换很多源会攒一堆大字典）
        if cache.count > 24 {
            // 只留最近的：先按插入顺序砍一半（简单粗暴，但够用）
            for k in cache.keys.sorted().prefix(cache.count / 2) { cache.removeValue(forKey: k) }
        }
        lock.unlock()
        return obj
    }
}
