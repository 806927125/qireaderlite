// ⭐⭐⭐⭐⭐ **Linux 沙盒桩**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️⚠️⚠️ **为什么要有这个文件**（沿用本仓库 `ChaiyueEngine/JS/JSStubs.swift` 的既有做法）⭐⭐⭐
//   `ReaderThemeScript`（阅读主题脚本：页眉/页脚/段落分类）依赖 **JavaScriptCore** ⭐⭐⭐
//   ⇒ **Linux 沙盒没有 JSC** ⇒ 真实实现在 `#if canImport(JavaScriptCore)` 里，Linux 上不存在 ⭐⭐⭐
//   ⇒ 但 `ChaiyueReaderKit` 本身要能在 Linux 编（沙盒门禁）⇒ 这里给一个**同 API 的桩** ⭐⭐⭐
//
// ⭐⭐⭐ **桩的行为必须「如实失败」，不能伪装成功**（否则门禁会假绿）⭐⭐⭐
//   ⇒ `isUsable` 恒为 false；`header` / `footer` / `paragraphClasses` 一律返回空 ⭐⭐⭐
//   ⇒ `error` 如实说明「当前平台没有 JavaScriptCore」⭐⭐⭐
#if !canImport(JavaScriptCore)
import Foundation

/// Linux 桩：阅读主题脚本（真实实现见 `ReaderThemeScript.swift`，Apple 平台走那条路 ⇒ 桩完全不参与）
public final class ReaderThemeScript: @unchecked Sendable {
    public private(set) var error: String?
    public private(set) var hasHeader = false
    public private(set) var hasFooter = false
    public private(set) var hasParagraphClass = false
    /// 超时或出错次数过多后停用
    public private(set) var disabled = false
    /// 运行中输出的 console.log 与异常，供编辑器显示
    public var log: [String] { ["当前平台没有 JavaScriptCore：主题脚本未执行"] }

    public init(source: String, timeout: TimeInterval = 1) {
        error = "当前平台没有 JavaScriptCore，无法执行主题脚本"
        disabled = true
    }

    public var isUsable: Bool { false }

    public func header(_ ctx: ReaderScriptContext) -> ReaderChromeText? { nil }

    public func footer(_ ctx: ReaderScriptContext) -> ReaderChromeText? { nil }

    /// 一章所有段落的类名，下标为段落序号；没有类的段落不出现
    public func paragraphClasses(_ paragraphs: [String]) -> [Int: String] { [:] }
}
#endif  // #if !canImport(JavaScriptCore)
