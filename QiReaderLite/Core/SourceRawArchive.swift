import Foundation

/// ⭐⭐⭐ **书源「原始 JSON 存档」**（导入时留一份）
///
/// ⚠️⚠️ **为什么需要**（2026-10-24 真机：「登录界面整没了」）：
///   `BookSource` 是**白名单解码**（`init(from:)` 只认模型里写了的键）
///   ⇒ **凡是模型后来才加的字段，凡是那之前导入并存下来的源，全都缺** ⭐
///   - `loginUi` 是 **build153** 才加的 ⇒ **在那之前导入的源，存储里根本没这个键**
///     ⇒ 登录面板永远显示「这个书源没有登录界面（loginUi 是空的）」
///     ⇒ 站方 19 个登录按钮 + 邮箱/密码输入框**一起消失** ⭐⭐⭐
///   - 同理会丢的还有 `jsLib` / `loginUrl` / `header` / `searchUrl` / `exploreUrl`
///     ⇒ 「站方 JS 跑不起来」「请求头丢了」「搜索/发现静默失效」「默认变量拉不到」
///       **全是同源** ⭐⭐⭐
///
/// ⇒ **两条修法**（缺一不可）：
///   ① **导入时**用原始 JSON 补齐（`BookSourceParser.patchMissingFields`）
///      —— 但**只对「重新导入过的源」有效**
///   ② ⭐ **把原始 JSON 存下来** ⇒ 以后模型再加字段，**老源也能从存档里补**
///      ⇒ **不用重新导入** ⇒ 这条才是根治 ⭐
///
/// 存储：`Documents/QRSourceRaw/<hash>.json`（一个源一份）
/// ⚠️ 用 **FNV-1a** 算文件名（不依赖 CryptoKit ⇒ Linux 沙盒也能编真跑）
enum SourceRawArchive {
    private static var dir: URL {
        // ⚠️ Linux 沙盒没有 documentDirectory ⇒ 回退到临时目录（门禁才能真跑）
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("QRSourceRaw", isDirectory: true)
    }

    /// 稳定的文件名（FNV-1a 64 位 → hex）
    private static func fileName(_ sourceUrl: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in sourceUrl.utf8 {
            hash ^= UInt64(b)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx.json", hash)
    }

    /// 存一份原始 JSON（导入时调）
    static func save(_ raw: [String: Any], for sourceUrl: String) {
        guard !sourceUrl.isEmpty,
              JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // ⭐⭐⭐ **不用 `.atomic`**（2026-10-26 iOS「diskwrites」限额被杀）⭐⭐⭐
        let target = dir.appendingPathComponent(fileName(sourceUrl))
        HostTools.writeAtomicallyFree(data, to: target)
        DiskWriteMeter.record(data.count)
    }

    /// 取某个源的原始 JSON（没有存档 = nil）
    static func raw(for sourceUrl: String) -> [String: Any]? {
        guard !sourceUrl.isEmpty else { return nil }
        let url = dir.appendingPathComponent(fileName(sourceUrl))
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// ⭐⭐⭐ **用存档把模型缺的字段补回来**
    ///
    /// ⇒ **在「源被用」之前调**（Store 载入/导入时调一次 ⇒ 全 App 都看到完整的源）
    static func patch(_ source: BookSource) -> BookSource {
        // ⭐ 只在「模型有缺口」时才去读存档
        //   （否则每次载入都要把所有源的大 JSON 读一遍 ⇒ 白白拖慢启动）
        let hasGap = (source.loginUi ?? "").isEmpty
            || (source.jsLib ?? "").isEmpty
            || (source.loginUrl ?? "").isEmpty
            || (source.searchUrl ?? "").isEmpty
            || (source.exploreUrl ?? "").isEmpty
        guard hasGap else { return source }
        guard let raw = raw(for: source.bookSourceUrl) else { return source }
        return BookSourceParser.patchMissingFields(source, from: raw)
    }
}
