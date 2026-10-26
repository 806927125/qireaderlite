import Foundation

// ⭐⭐⭐⭐⭐ **磁盘路径**（2026-10-26 从 `Store.swift` 拆出来）
//
// ⚠️⚠️ **为什么拆**：`AppPaths` 本来和 SwiftUI 的 `SourceStore` 同文件
//   ⇒ `Store.swift` 带 `import SwiftUI` ⇒ **Linux 沙盒编不了** ⭐⭐⭐
//   ⇒ 而 `HostTools.swift` 的 `CacheFiles` 用到 `AppPaths.cacheDir`
//   ⇒ 不编它 ⇒ 门禁报「cannot find 'AppPaths' in scope」⇒ **真错看不见** ⭐⭐⭐
//   ⇒ 拆成独立文件（**纯 Foundation**）⇒ 两边都能编 ⭐⭐⭐
//
// ⭐⭐⭐ **通用判据**：**要进沙盒门禁的类型 ⇒ 必须住在纯 Foundation 的文件里**
//   ⇒ 混在带 UIKit/SwiftUI 的文件里 ⇒ 门禁只能 stub 掉 ⇒ **类型错就抓不到了** ⭐⭐⭐
//
// MARK: - 磁盘路径

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
    /// ⭐⭐⭐⭐⭐ **内存水位档案**（2026-10-26 build263）
    ///
    /// ⚠️⚠️ **为什么必须落盘**：jetsam 杀进程 ⇒ **内存里的峰值/日志一起没了**
    ///   ⇒ 崩了之后再打开面板，**看不到「被杀前涨到多少」** ⇒ 白查一轮 ⭐⭐⭐
    /// ⇒ ⇒ 峰值 + 采样（带 op 名）写到这个**小文件** ⇒ 下次打开面板就能看到 ⭐⭐⭐
    static var memMeterFile: URL { documents.appendingPathComponent("memory-meter.json") }
    static var cacheDir: URL {
        let d = documents.appendingPathComponent("content_cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}
