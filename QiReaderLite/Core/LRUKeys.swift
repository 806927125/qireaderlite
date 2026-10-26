import Foundation

/// ⭐⭐⭐⭐⭐ **LRU 顺序表（只管 key，不管值）**
///
/// ⚠️ **为什么单独拆成一个文件**（2026-10-26 jetsam 6.8GB 实证）：
///   会话封顶的**逻辑**（碰到就提到最近 / 超额淘汰最旧）必须**能在沙盒里真跑**
///   ⇒ 就不能埋在依赖 `LegadoCore` 的适配层（`LegadoEngineBackend`）里
///     （那一层在 Linux 上编不过 ⇒ 逻辑就永远没被验过）⭐⭐⭐
///   ⇒ 拆成**纯 Foundation** 的小件 ⇒ 3 秒就能测 ⇒ 门禁能真验 ⭐⭐⭐
///
/// ⭐ **它解决的是什么问题**：
///   一个书源 = 一个引擎会话 = **一个 JSC context**（站方 JS 的全局都活在里面）
///   ⇒ 会话只增不减 ⇒ **内存随「用过的源数」线性涨**
///   ⇒ 用户有 125 个源、搜索默认扫所有启用的源 ⇒ 一次搜索就建几十个 context
///   ⇒ 老引擎（WKWebView）的 JS 在**别的进程** ⇒ 同样的脚本 App 内存不受影响
///   ⇒ 所以**老引擎一点问题没有**，新引擎进 App 进程就撑爆 ⇒ jetsam 杀 App ⭐⭐⭐
final class LRUKeys {

    /// ⭐ 顺序（**最旧在前**）
    private(set) var order: [String] = []

    /// ⭐ 上限（最多留几个 key ⇒ 值那边就最多留几个会话）
    let limit: Int

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    var count: Int { order.count }

    /// ⭐ 命中 ⇒ 把它挪到「最近使用」端
    func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    /// ⭐ 新增一个 key ⇒ **超上限时返回「最久未用的那个」**（由调用方去淘汰它的值）
    @discardableResult
    func insert(_ key: String) -> String? {
        touch(key)
        while order.count > limit {
            let oldest = order.removeFirst()
            // ⚠️ 理论上被淘汰的不会是刚插的那个（limit ≥ 1）⇒ 兜底放回去
            if oldest == key {
                order.append(oldest)
                return nil
            }
            return oldest
        }
        return nil
    }

    func remove(_ key: String) {
        order.removeAll { $0 == key }
    }

    func removeAll() {
        order.removeAll()
    }

    /// ⭐ 最久未用的那个（没有 ⇒ nil）
    var oldest: String? { order.first }
}
