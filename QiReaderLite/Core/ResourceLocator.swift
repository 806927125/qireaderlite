import Foundation

/// ⭐⭐⭐ **资源定位**（2026-11-19 · 老 `RuleSandbox` 删掉后独立出来）
///
/// 老 `RuleSandbox` 里还有一段「在沙盒 Documents 里找同名资源」的逻辑（给引擎 JS 文件用）。
/// ⇒ 老引擎（`Resources/engine/*.js`）退役后那段只剩**阅读器的 `reader.html`** 要用 ⇒ 单独留下 ⭐⭐⭐
enum ResourceLocator {
    /// 找同名资源：① App 包里 ② Documents（用户可覆盖）
    static func locate(_ name: String) -> URL? {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        // ① App 包
        if let url = Bundle.main.url(forResource: base, withExtension: ext.isEmpty ? nil : ext) {
            return url
        }
        // ② Documents（用户自己放的同名资源优先）
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let docs {
            let custom = docs.appendingPathComponent(base + "." + ext)
            if FileManager.default.fileExists(atPath: custom.path) { return custom }
            let inRoot = docs.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: inRoot.path) { return inRoot }
        }
        return nil
    }
}
