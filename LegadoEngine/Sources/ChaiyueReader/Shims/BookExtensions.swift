#if os(iOS)
// ⭐⭐⭐⭐⭐ **柴阅的 `Book` 扩展（我们补的）**（2026-11-26 · CI327 实证）⭐⭐⭐⭐⭐
//
// ⚠️⚠️ **为什么需要**（CI327 的报错是「value of type 'Book' has no member 'hasStarted'」）⭐⭐⭐：
//   柴阅上游把 `hasStarted` 写在 **`App/Sources/Screens/Shelf/HeroCard.swift`**（**App 层**！）
//   ⇒ 它是「书架封面组件」顺手写的扩展 ⇒ 我们搬 App 层时**没带它** ⭐⭐⭐
//   ⇒ 而柴阅的 `MediaKindStyle.actionTitle(for:)`（我们搬进包里的）要用它
//   ⇒ 「开始阅读 / 继续阅读」这个文案就编不过了 ⭐⭐⭐
//
// ⚠️ **上游原文**（`App/Sources/Screens/Shelf/HeroCard.swift`）：
//   ```swift
//   extension Book {
//       var hasStarted: Bool { durChapterIndex > 0 || durChapterPos > 0 }
//   }
//   ```
//   ⇒ 这里**一字不改**地补上，并升 `public`（宿主也要用：详情页按钮写「继续看漫画」）⭐⭐⭐
import ChaiyueModels

extension Book {
    /// 已读过的书（章号或章内位置有值）
    public var hasStarted: Bool { durChapterIndex > 0 || durChapterPos > 0 }
}
#endif  // #if os(iOS)
