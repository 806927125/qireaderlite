import Foundation

// ⭐⭐⭐ **磁盘路径**（2026-11-19 · 从 `Store.swift` 拆出 ⇒ 纯 Foundation ⇒ Linux 门禁能真编）
enum AppPaths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var sourcesFile: URL { documents.appendingPathComponent("book_sources.json") }
    /// 从 Info.plist 读版本号，自检面板用
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
    /// **build 号**（CFBundleVersion）—— 唯一能区分「新包/旧包」的标识
    ///
    /// ⚠️ 之前自检面板只显示「App 版本：3.6」⇒ 用户和我都**分不清装的是哪一版**
    ///    （今天连着几个 build 的包混着装）⇒ 报 bug 时根本对不上号。
    /// ⇒ 现在自检面板第一行就显示 `App 3.6 (build 173)` ✅
    static var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }
    /// 「3.6 (build 173)」这种一眼能看的写法
    static var appVersionLine: String { "\(appVersion) (build \(appBuild))" }
    static var libraryFile: URL { documents.appendingPathComponent("library.json") }
    /// ⭐⭐⭐ **柴阅阅读器的数据目录**（2026-11-25 接柴阅阅读器）⭐⭐⭐
    ///
    /// ⚠️ 柴阅的阅读链路要落盘的东西（书架 / 书源副本 / 章节缓存 / 阅读记录 / 书签）
    ///   ⇒ 轻阅侧给它一个**独立目录** ⇒ 跟轻阅自己的 `library.json` 互不干扰 ⭐⭐⭐
    ///   ⇒ 「轻阅书库」仍是轻阅的主数据源 ⇒ 柴阅这份是**阅读期镜像**（见 `ChaiyueReaderHost`）⭐⭐⭐
    static var chaiyueDir: URL {
        let d = documents.appendingPathComponent("ChaiyueReader", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static var cacheDir: URL {
        let d = documents.appendingPathComponent("content_cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}
