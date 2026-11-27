#if os(iOS)
// ⭐⭐⭐⭐⭐ **【平台守卫】本文件的依赖只在 iOS 存在**（2026-11-26）⭐⭐⭐⭐⭐
//   ⚠️ **为什么**：`LegadoEngine`（宿主门面模块）现在依赖 `ChaiyueReader`
//     ⇒ ⇒ **macOS / Linux 上会编译 `ChaiyueReader` 模块**（以前只编 iOS ⇒ 没暴露）⭐⭐⭐
//   ⇒ 而本文件引用的类型（ReaderChrome 等）在那些平台**不存在** ⇒ 编译失败 ⭐⭐⭐
//   ⇒ 正解：**把本文件也圈进 iOS** ⇒ 各平台一致 ⭐⭐⭐
import SwiftUI
import ChaiyueModels

// =============================================================================
// ⭐⭐⭐ **柴阅 App 层「换源 / TXT 分章」两个面板的轻阅实现**（2026-11-26）⭐⭐⭐
//
// ⚠️ 柴阅的阅读器顶栏会弹这两个面板（`ReaderChrome` 里 `.sheet { ChangeSourceSheet(...) }`
//   与 `.sheet { TxtSplitSheet(...) }`）⇒ **类型必须存在**，否则阅读器编不过 ⭐⭐⭐
//   而它们的完整实现拖着一整套 **本地书/搜索服务**（SourceCandidate / ChangeSourceModel /
//   TxtChapterSplitter / TextEncodingDetector / txtTocRules / resplitLocalBook …）⭐⭐⭐
//   ⇒ 轻阅**没有本地书功能**、换源走站方自己的登录界面 ⇒ 这两个面板**功能上用不到** ⭐⭐⭐
//   ⇒ 保留**类型面 + 空实现** ⇒ 阅读器照常编译/打开，面板本身是空的 ⭐⭐⭐
//   ⇒ ⚠️ 已知功能缺口：应用内换源 / TXT 分章重排（不影响阅读）⭐⭐⭐
// =============================================================================

#if os(iOS)

/// 换源面板（轻阅：空实现）
struct ChangeSourceSheet: View {
    let book: Book
    let onChanged: (Book) -> Void

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
    }
}

/// TXT 分章/重排面板（轻阅：空实现）
struct TxtSplitSheet: View {
    let book: Book
    let onChanged: (Book) -> Void

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
    }
}

#endif  // #if os(iOS)
#endif  // #if os(iOS)
