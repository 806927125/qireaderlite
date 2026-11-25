#if os(iOS)
// ⭐⭐⭐⭐⭐ **宿主可见性出口**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **为什么需要这个文件**：SwiftPM 的 **product 不 re-export 依赖模块** ⭐⭐⭐
//   ⇒ 宿主（Xcode 工程只链 `LegadoEngine` + `ChaiyueReader` 两个 product）
//     写 `import ChaiyueReaderServices` 会报 **no such module** ⭐⭐⭐
//     ⇒ `ReaderSession` / `BookContentService` / `ContentProcessor` / `BookshelfRepository`
//       / `SourceRepository` / `HttpTTSRepository` 宿主全都拿不到 ⭐⭐⭐
//   ⇒ 这里用 `@_exported` 把三个模块**再导出** ⇒ 宿主 `import ChaiyueReader` 一行就够 ⭐⭐⭐
//
// ⚠️⚠️ **关于命名冲突**：`@_exported import ChaiyueModels` 会把 `Book` / `BookSource` 等倒进宿主命名空间。
//   ⇒ 宿主侧用**别名**区分（`LegadoEngineHost.BookModel` / `QiBook` …）即可 ⇒ 互不干扰 ⭐⭐⭐
//
// ⚠️ **`ChaiyueEngine` 不整体倒出**：引擎里有 `Book` / `BookSource` 等同名类型，整体倒出会放大撞名面；
//   ⇒ 只精确转出宿主需要的 `SourceCallBackEvent`（`ChaiyueReaderLibrary` 协议要用）⭐⭐⭐
@_exported import ChaiyueModels
@_exported import ChaiyueReaderKit
@_exported import ChaiyueReaderServices

import ChaiyueEngine

/// 书源脚本发给界面的一次性事件（宿主实现 `ChaiyueReaderLibrary.callBack(_:book:chapter:)` 时要用）
public typealias SourceCallBackEvent = ChaiyueEngine.SourceCallBackEvent
#endif  // #if os(iOS)
