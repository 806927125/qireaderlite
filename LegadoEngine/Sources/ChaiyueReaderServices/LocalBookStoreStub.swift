import Foundation
import ChaiyueModels

// =============================================================================
// ⭐⭐⭐⭐⭐ **本地书仓（轻阅侧的最小实现）**（2026-11-25 · 柴阅阅读器 vendor）⭐⭐⭐⭐⭐
//
// ⚠️⚠️⚠️ **为什么是桩而不是柴阅原版** ⭐⭐⭐：
//   柴阅原版 `ReaderServices/LocalBooks/` 有 **14 个文件**（EPUB / Mobi / DOCX / FB2 /
//   Rtf / Umd / Markdown / HTML 解析器 + TXT 分章器 + 编码探测 + 语音包导入）⭐⭐⭐
//   ⇒ 那是**「本地书」这个功能**，不是「阅读器」本身 ⭐⭐⭐
//   ⇒ 轻阅的阅读器当前**不支持本地书**（没有导入入口、没有书架里的本地书条目）⭐⭐⭐
//   ⇒ ⇒ **不搬**：搬进来就是几百行用不到的解析器，还要拖 EPUB/编码/分章一整套依赖 ⭐⭐⭐
//   ⇒ ⇒ **只保留类型与调用面**：让 `BookContentService` 能编过，且真走到本地书时**明确报错**
//     （而不是静默返回空内容 ⇒ 用户看到「目录 0 章」却不知道原因）⭐⭐⭐
//
// ⭐ **判据**：`handles(_:)` 永远 false ⇒ 网络书路径**完全不受影响**；
//   真要支持本地书时，把柴阅的 `LocalBooks/` 整目录搬进来 + 把 `handles` 改成真实判断即可 ⭐⭐⭐
// =============================================================================

/// 本地书仓（轻阅侧为桩：只保留调用面，本地书功能未接）
public final class LocalBookStore: Sendable {
    /// 柴阅原版的初始化是 `init(root: URL)`（本地书根目录）；轻阅这里保留同签名以便将来直接换回原版 ⭐⭐⭐
    public init(root: URL) {}

    /// 轻阅没有本地书 ⇒ 一律 false ⇒ 永远走网络书路径 ⭐⭐⭐
    public static func handles(_ url: String) -> Bool { false }

    /// 非 EPUB（轻阅侧不区分 TXT/EPUB）⇒ 一律 false
    public func isEpub(_ book: Book) -> Bool { false }

    /// 非文本书（同样不区分）
    public func isTextBook(_ book: Book) -> Bool { false }

    /// ⭐⭐⭐ **明确失败**（不是静默空数组）⇒ 宿主能区分「没有本地书」与「解析失败」⭐⭐⭐
    public func chapters(for book: Book) throws -> [BookChapter] {
        throw BookServiceError.localBooksUnavailable
    }

    public func content(for book: Book, chapter: BookChapter) throws -> String {
        throw BookServiceError.localBooksUnavailable
    }

    public func resourceData(_ url: String) throws -> Data {
        throw BookServiceError.localBooksUnavailable
    }
}
