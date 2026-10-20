import Foundation

/// Legado 兼容层的「纯计算能力」—— **一律用 Swift 写**，JS 只做转发。
///
/// 为什么不写在 JS 里：
/// 1. `Core/` 是**纯 Foundation 层**，沙盒里能 `swiftc` 真编真测 → 改完 3 秒出结果，
///    不用等 CI（SwiftUI 层在沙盒里只能靠 CI 验编译）。
/// 2. 逻辑沉在原生侧，行为不会受 WebView 的 JS 引擎差异影响。
/// 3. 站方 JS 依赖这些能力的**精确语义**（Legado 的 `java.timeFormat` 是 Long → String），
///    在 JS 里自己实现很容易搞成「差不多但不一样」，然后站方拼卡片时炸在一个莫名其妙的地方。
///
/// ⚠️ 站方有**同步**调用原生能力的地方：
///     java.timeFormat(res.register_time*1000).padEnd(20,"\t")
/// `.padEnd` 必须在同一个同步表达式里 → 原生桥的 postMessage（异步）**用不了**。
/// 唯一能同步拿到原生返回值的通道是 `window.prompt`（见 `RuleSandbox` 的 WKUIDelegate）。
enum LegadoCompat {

    // MARK: - java.timeFormat

    /// Legado 的 `java.timeFormat` —— **Long(epoch 毫秒) → 字符串**。
    ///
    /// 站方拼会员卡片就是这么用的：
    ///     java.timeFormat(res.register_time*1000).padEnd(20, "\t")
    ///     java.timeFormat(new Date()).slice(0,10) == java.timeFormat(res.last_read_time*1000).slice(0,10)
    /// 后者还要求 `.slice(0,10)` 正好是 `yyyy-MM-dd`。
    enum TimeFormat {
        /// 毫秒 → "yyyy-MM-dd HH:mm:ss"（本地时区）
        static func format(ms: Int64) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000.0))
        }

        /// 日期字符串 → epoch 毫秒（解析不了给 0，跟 Legado 一样不抛）
        ///
        /// 语料里大量这种写法，拿来当章节时间戳：
        ///     java.timeFormat(java.getString('$.updateDate'))
        ///
        /// ⚠️ 用 **UTC** 解释（跟原来 JS 版 `Date.UTC(...)` 一致）——
        ///    换成本地时区会差一个时区偏移，章节时间就全变了。
        static func parse(_ text: String) -> Int64 {
            let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { return 0 }
            // 纯数字：秒还是毫秒？（10 位及以下当秒）
            if s.allSatisfy({ $0.isNumber }) {
                let n = Int64(s) ?? 0
                return s.count <= 10 ? n * 1000 : n
            }
            let patterns = [
                "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy/MM/dd HH:mm:ss",
                "yyyy-MM-dd HH:mm", "yyyy-MM-dd", "yyyy/MM/dd", "yyyy年MM月dd日 HH:mm:ss",
                "yyyy年MM月dd日"
            ]
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)   // ← UTC
            for p in patterns {
                formatter.dateFormat = p
                if let d = formatter.date(from: s) {
                    return Int64(d.timeIntervalSince1970 * 1000)
                }
            }
            // 兜底：交给系统解析（"Mon Oct 20 2026 ..." 这类）
            if let d = ISO8601DateFormatter().date(from: s) {
                return Int64(d.timeIntervalSince1970 * 1000)
            }
            return 0
        }

        /// **统一入口**：按输入形态决定语义。
        ///
        /// - 数字 / 纯数字字符串 → epoch 毫秒 → **格式化字符串**（Legado 语义）
        /// - 其它字符串 → 解析成 **epoch 毫秒**（语料里当章节时间戳用）
        ///
        /// 返回 `Any` 是因为两种语义的结果类型不同（String / Int64），
        /// 同步通道走 JSON，类型会原样带过去。
        static func apply(_ input: String) -> Any {
            let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { return "" }
            if s.allSatisfy({ $0.isNumber }) {
                let n = Int64(s) ?? 0
                let ms = s.count <= 10 ? n * 1000 : n
                return format(ms: ms)
            }
            return parse(s)
        }
    }

    // MARK: - cache.put / cache.get / cache.remove

    /// Legado 的 `cache`（BookCacheManager 那种 KV）。
    ///
    /// ⚠️ **注意站方怎么用它**（🍅大灰狼的 `putLoginInfo`）：
    ///     try {
    ///         let encodeStr = Base64.encodeToString(createSymmetricCrypto("AES", androidId).encrypt(info), 2)
    ///         cache.put(`userInfo_${source.getKey()}`, encodeStr)
    ///         return true
    ///     } catch (e) {
    ///         java.log(e)
    ///         return source.putLoginInfo(info)     // ← 轻阅走的是这条
    ///     }
    /// 站方把登录信息**加密**后存 cache，而它自己从来不读回（没有 cache.get）。
    /// 轻阅的登录信息必须留在 `source.putLoginInfo`（书源登录信息表），
    /// 否则下次启动 `login()` 读 `source.getLoginInfo()` 会拿到空 → **登录态丢失**。
    /// 所以 JS 侧 `cache.put` 存完之后**仍要抛错**，好让站方走那条 fallback。
    enum Cache {
        private static let prefix = "legadocache."

        static func put(_ key: String, _ value: String) {
            UserDefaults.standard.set(value, forKey: prefix + key)
        }

        static func get(_ key: String) -> String {
            UserDefaults.standard.string(forKey: prefix + key) ?? ""
        }

        static func remove(_ key: String) {
            UserDefaults.standard.removeObject(forKey: prefix + key)
        }
    }

    // MARK: - 同步通道分发

    /// 同步通道的**唯一**入口：JS 通过 `window.prompt` 把 {fn, args} 送过来，
    /// 这里回一个 JSON 串（`{"ok":true,"value":...}` 或 `{"ok":false,"error":...}`）。
    static func handle(fn: String, args: [String: Any]) -> [String: Any] {
        switch fn {
        case "timeFormat":
            let input = args["input"] as? String ?? ""
            let v = TimeFormat.apply(input)
            // 数字结果在 JSON 里会变成 number，字符串就是 string —— 原样带回去
            if let n = v as? Int64 { return ["ok": true, "value": n] }
            return ["ok": true, "value": String(describing: v)]

        case "cachePut":
            let key = args["key"] as? String ?? ""
            let value = args["value"] as? String ?? ""
            Cache.put(key, value)
            return ["ok": true, "value": "1"]

        case "cacheGet":
            let key = args["key"] as? String ?? ""
            return ["ok": true, "value": Cache.get(key)]

        case "cacheRemove":
            let key = args["key"] as? String ?? ""
            Cache.remove(key)
            return ["ok": true, "value": "1"]

        default:
            return ["ok": false, "error": "未知能力: \(fn)"]
        }
    }
}
