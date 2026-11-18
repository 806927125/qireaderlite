import Foundation

/// ⭐⭐⭐ **宿主适配入口**（2026-11-19 追加）
///
/// ⚠️ **为什么需要**：模块名 `LegadoEngine` 与引擎里的门面 enum `LegadoEngine` **同名**
///   ⇒ 宿主侧写 `LegadoEngine.BookSource` 会被那个 enum 遮蔽（不是模块）⇒ 编译不过 ⭐⭐⭐
///   ⇒ ⇒ 这里给一组**唯一命名**的类型别名 ⇒ 宿主侧用 `LegadoEngineHost.Source` 等
///   ⇒ **不改动引擎原有的任何 API**（纯追加）⭐⭐⭐
///
/// ⚠️ **别名不能跟原类型同名**（`typealias Book = Book` ⇒ “references itself”）⭐⭐⭐
public enum LegadoEngineHost {
    public typealias Source = BookSource
    public typealias BookModel = Book
    public typealias ChapterModel = BookChapter
    public typealias SearchResult = SearchBook
    public typealias Kind = ExploreKind
    public typealias Vars = RuleVariables
    public typealias UrlBuilder = AnalyzeUrl
    #if canImport(JavaScriptCore) && !os(Linux)
    /// ⚠️ **JS 层只在 Apple 平台存在**（Linux 分支没有 JSC）⇒ 别处不能引用这两个别名 ⭐⭐⭐
    public typealias Bridge = JSBridge
    public typealias Host = JSHost
    #endif
}
