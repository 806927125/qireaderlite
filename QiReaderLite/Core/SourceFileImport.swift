import Foundation

/// ⭐⭐⭐⭐⭐ **从「文件 / 分享」导入书源**（2026-10-26 用户反馈：「文件导入书源用不了，选中打不开」）
///
/// ⚠️⚠️ **自签安装包尤其容易踩**：
///   ① **App 必须声明能打开 .json**（Info.plist 的 `CFBundleDocumentTypes`）
///      ⇒ 否则 iOS **根本不会**把文件路由给 App ⇒ 「从文件 App 里点 json ⇒ 打开方式里没有轻阅」⭐⭐⭐
///   ② **App 必须有 `onOpenURL` 入口** ⇒ 否则文件送进来了也没人接 ⇒ 静默无反应 ⭐⭐⭐
///   ③ iOS 送进来的 URL 是**安全作用域**的 ⇒ 必须 `startAccessingSecurityScopedResource()`
///      ⇒ 不开就 `Data(contentsOf:)` 直接失败（自签包尤其明显）⭐⭐⭐
///
/// ⇒ 三样缺一样，都是「选中打不开」——**症状一样，根因三个** ⭐⭐⭐
enum SourceFileImport {

    /// 读一个文件并导入书源 ⇒ 返回导入个数
    /// - Note: 必须先开安全作用域；读不出来**明确报错**（不许静默）
    @discardableResult
    @MainActor
    static func importFile(_ url: URL, into store: SourceStore) throws -> Int {
        // ⭐ 安全作用域只有 Apple 平台有 ⇒ Linux 沙盒门禁要能编过 ⇒ 用 #if 收起来
        #if canImport(Darwin)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        #endif
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SourceImportError.readFailed(url.lastPathComponent, error.localizedDescription)
        }
        do {
            let list = try BookSourceParser.parse(data)
            return store.importSources(list)
        } catch {
            throw SourceImportError.parseFailed(url.lastPathComponent, error.localizedDescription)
        }
    }
}

/// 导入失败的原因（**分清「读不到」和「解析不了」**——前者是权限/文件问题，后者是内容问题）
enum SourceImportError: LocalizedError {
    case readFailed(String, String)
    case parseFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .readFailed(let name, let why):
            return "读不到「\(name)」：\(why)\n（自签包请确认：文件在「文件」App 里可见、且 App 已声明能打开 JSON）"
        case .parseFailed(let name, let why):
            return "「\(name)」不是合法的书源 JSON：\(why)"
        }
    }
}
