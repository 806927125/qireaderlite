import SwiftUI
import LegadoEngine
import ChaiyueReader

// ⭐⭐⭐⭐⭐ **宿主侧的漫画阅读页**（2026-11-26 · 柴阅漫画阅读器 vendor）⭐⭐⭐⭐⭐
//
// ⚠️⚠️⚠️ **为什么需要它** ⭐⭐⭐：
//   柴阅的漫画阅读器（`ComicReaderScreen`）是**包内 internal 类型** ⇒ 宿主要开它
//   ⇒ 但它需要 `@Environment(AppModel.self)` ⇒ 宿主得先造一个 `AppModel` ⭐⭐⭐
//   ⇒ 所以宿主这层做三件事：
//     ① 造 `ChaiyueReaderHost(mode: .comic)`（**与文字阅读器共用同一套镜像/目录预写逻辑**
//        ⇒ 目录已在详情页取过 ⇒ 这里命中章节缓存 ⇒ **不重复请求站方**）⭐⭐⭐
//     ② 把柴阅的 `MediaLaunch`（`app.media`）交给 `ComicReaderScreen` ⭐⭐⭐
//     ③ 漫画页收起（`app.closeMedia()` ⇒ `app.media` 变 nil）⇒ 回写进度 + 退出 ⭐⭐⭐
//
// ⚠️ **漫画的图从哪来**：站方把**章节正文返回成一堆 `<img>`** ⇒ 柴阅的
//   `MediaSession.images(at:)` 从正文里抽图片地址（`ChapterText.imageSources`）
//   ⇒ **数据链已经在包里**（`MediaSession` + `ChapterText` 都在 `ChaiyueReaderServices`）⭐⭐⭐
//   ⇒ 这正是轻阅老 WebView 阅读器时代能看漫画的那条路 ⇒ 现在用柴阅原版的翻页体验 ⭐⭐⭐
struct ChaiyueComicScreen: View {
    /// 轻阅侧的书
    let book: QiBook
    /// 轻阅侧的目录（详情页已经取好 ⇒ 预写进柴阅的章节缓存 ⇒ 漫画页命中缓存）⭐⭐⭐
    let chapters: [QiChapter]
    /// 从哪一章开始（nil = 接着上次看的）
    let start: QiChapter?

    @EnvironmentObject private var sources: SourceStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    /// 宿主对象（造柴阅的 `AppModel` + 镜像书架/书源/目录）
    @State private var host: ChaiyueReaderHost?
    /// 起不来时的兜底提示
    @State private var errorText: String?

    var body: some View {
        ZStack {
            if let host, let launch = host.app.media {
                // ⭐⭐⭐⭐⭐ **柴阅的漫画阅读界面本体** ⭐⭐⭐⭐⭐
                //   · `ComicReaderScreen` = 柴阅 `App/Sources/Media/Comic/ComicReaderScreen.swift` 原版 ⭐⭐⭐
                //   · `.environment(host.app)` = 柴阅的 `@Environment(AppModel.self)` ⭐⭐⭐
                ComicReaderScreen(launch: launch)
                    .environment(host.app)
            } else if let errorText {
                failure(errorText)
            } else {
                Color.black.ignoresSafeArea()
                ProgressView().tint(.white)
            }
        }
        .task { prepare() }
        // ⭐⭐⭐ 柴阅的漫画页收起时会 `app.closeMedia()` ⇒ `app.media` 置 nil ⇒ 这里跟着收摊 ⭐⭐⭐
        .onChange(of: host?.app.media) { _, newValue in
            if newValue == nil, host != nil { close() }
        }
    }

    // MARK: - 准备

    @MainActor
    private func prepare() {
        guard host == nil, errorText == nil else { return }
        let source = sources.source(id: book.origin)
        let progress = library.item(for: book.id)?.lastChapterIndex ?? 0
        let h = ChaiyueReaderHost(book: book,
                                  chapters: chapters,
                                  start: start,
                                  source: source,
                                  libraryItems: library.items,
                                  progressIndex: progress,
                                  mode: .comic)
        // ⚠️ **先校验再挂上去**（挂上去就进 `if let host` 分支 ⇒ 兜底界面永远看不见）⭐⭐⭐
        if h.chaiyueBook.name.isEmpty {
            errorText = "这本书的信息不完整（书名是空的）"
            return
        }
        host = h
    }

    // MARK: - 关闭

    @MainActor
    private func close() {
        // ⭐⭐⭐ 进度回写：柴阅的 `MediaSession` 已经把进度写进柴阅的书架仓
        //   ⇒ 这里把它搬回轻阅的书库（轻阅的书库才是主数据）⭐⭐⭐
        host?.writeBackProgress(to: library)
        dismiss()
    }

    // MARK: - 兜底

    private func failure(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("返回") { dismiss() }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.16), in: Capsule())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
