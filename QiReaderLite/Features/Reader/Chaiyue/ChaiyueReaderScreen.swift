import SwiftUI
import LegadoEngine
import ChaiyueReader

// ⭐⭐⭐⭐⭐ **柴阅阅读器的宿主视图**（2026-11-25 接柴阅阅读器）⭐⭐⭐⭐⭐
//
// ⚠️⚠️⚠️ **这里是「老阅读器 → 柴阅阅读器」的换乘点** ⭐⭐⭐：
//   以前这里开的是**我们自己手写**的那套阅读界面（WebView + 自研原生分页/滚动）⭐⭐⭐
//   ⇒ 现在换成**柴阅的 `ReaderContainer`**（`ChaiyueReader` 模块）
//     ⇒ 阅读正文界面 = **柴阅原版**（皮肤 / 页眉页脚 / 章节号装饰 / 段评气泡 / 朗读 / 目录 / 书签）⭐⭐⭐
//
// ⚠️ **命名纪律**：本文件 `import ChaiyueReader` ⇒ 柴阅的 `Book` / `BookSource` 也进了命名空间，
//   而宿主 App 侧同名 ⇒ 所以宿主类型一律写 `QiBook` / `QiChapter`（本地别名，唯一）⭐⭐⭐
struct ChaiyueReaderScreen: View {
    /// 轻阅侧的书
    let book: QiBook
    /// 轻阅侧的目录（详情页已经取好 ⇒ 直接喂给柴阅 ⇒ 不重复请求站方）⭐⭐⭐
    let chapters: [QiChapter]
    /// 从哪一章开始读（nil = 接着上次读的）
    let start: QiChapter?

    @EnvironmentObject private var sources: SourceStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    /// ⭐⭐⭐⭐⭐ **柴阅的外观档（system / light / dark）** ⭐⭐⭐⭐⭐
    ///
    /// ⚠️ **为什么宿主要读这个键**（2026-11-26 真机「日间夜间切换不了」）⭐⭐⭐：
    ///   柴阅的「日间 / 夜间」按钮调 `app.appearance.force(...)` ⇒ 包内 `AppearanceStore`
    ///   ⇒ 它**以前**改整个窗口的 `overrideUserInterfaceStyle`，
    ///   而轻阅**根部强制 `.preferredColorScheme(.dark)`** ⇒ 两边打架 ⇒ **切不动** ⭐⭐⭐
    ///   ⇒ 现在 `AppearanceStore.apply()` 只把状态写进 UserDefaults（键 `appearance`），
    ///     由**阅读器这一层**用 SwiftUI 的 `.preferredColorScheme` 施加 ⇒
    ///     **只有阅读器变浅色，轻阅其它界面永远深色**（玻璃按钮不乳白）⭐⭐⭐
    @AppStorage("appearance") private var appearance: String = "system"

    /// 宿主对象（造柴阅的 `AppModel` + 镜像书架/书源/目录）
    @State private var host: ChaiyueReaderHost?
    /// 柴阅的「打开阅读器」请求
    @State private var launch: ReaderLaunch?
    /// 起不来时的兜底提示（柴阅的阅读器是全屏的 ⇒ 我们自己给一个能退出来的界面）⭐⭐⭐
    @State private var errorText: String?

    var body: some View {
        ZStack {
            if let host, let launch = host.launch {
                // ⭐⭐⭐⭐⭐ **柴阅的阅读界面本体** ⭐⭐⭐⭐⭐
                //   · `ReaderContainer` = 柴阅 `App/Sources/Reader/ReaderContainer.swift` 原版 ⭐⭐⭐
                //   · `.environment(host.app)` = 柴阅的 `@Environment(AppModel.self)` ⭐⭐⭐
                //     （AppModel 是**我们 App 侧**造的 ⇒ shim 在宿主，不在包里）⭐⭐⭐
                ReaderContainer(launch: launch)
                    .environment(host.app)
            } else if let errorText {
                failure(errorText)
            } else {
                Color.black.ignoresSafeArea()
                ProgressView().tint(.white)
            }
        }
        .task { prepare() }
        // ⭐⭐⭐⭐⭐ **浏览器浮在【阅读器】之上**（2026-11-27 真机「段评要先回详情页」）⭐⭐⭐⭐⭐
        //   根 View 的 sheet 被 `fullScreenCover`（阅读器）压住 ⇒ 浏览器看不见 ⇒
        //   ⇒ 阅读器在场时改由**这一层**承载浏览器 ⇒ 浮在阅读器之上 ⇒ 关掉浏览器就回到正文 ⭐⭐⭐
        .sheet(item: Binding(
            get: { BrowserPresenter.shared.item?.onReader == true ? BrowserPresenter.shared.item : nil },
            set: { BrowserPresenter.shared.item = $0 }
        )) { item in
            BrowserSheet(url: item.url, title: item.title, onFinish: item.onFinish)
        }
        .onAppear { BrowserPresenter.shared.readerPresented = true }
        .onDisappear {
            BrowserPresenter.shared.readerPresented = false
            // ⚠️ 用户直接关阅读器而浏览器还开着 ⇒ 收掉浏览器并**回调空结果**
            //   （不回调 ⇒ 站方等的 `startBrowserAwait` 结果永远不来 ⇒ 卡死）⭐⭐⭐
            BrowserPresenter.shared.dismissIfReading()
        }
        // ⭐⭐⭐ 柴阅的阅读器关闭时会 `app.closeReader()` ⇒ `app.reader` 置 nil ⇒ 这里跟着收摊 ⭐⭐⭐
        .onChange(of: host?.app.reader) { _, newValue in
            if newValue == nil, launch != nil { close() }
        }
        // ⭐⭐⭐⭐⭐ **阅读器这一层的外观**（叶子优先 ⇒ 盖过根部的强制深色）⭐⭐⭐⭐⭐
        //   · 「日间」⇒ 包内 AppearanceStore 写 `appearance=light` ⇒ 这里切成浅色 ⇒
        //     纸面换成 `lightTheme` 槽、玻璃面板变浅 ⭐⭐⭐
        //   · 「自动」档在轻阅里**按深色处理**（轻阅全局强制深色 ⇒ 跟随系统会打回原形）⭐⭐⭐
        .preferredColorScheme(appearance == "light" ? .light : .dark)
    }

    // MARK: - 准备

    @MainActor
    private func prepare() {
        guard host == nil, errorText == nil else { return }
        // ⭐⭐⭐⭐⭐ **准备阶段日志**（2026-11-28 · 真机「点开始阅读闪退」取证）⭐⭐⭐⭐⭐
        //   ⇒ 日志最后一条 = 崩在哪一步 ⇒ 宿主写进「引擎日志」面板 ⇒ App 内可见 ⭐⭐⭐
        engineLog("[柴阅阅读器] prepare 开始 · 书=\(book.name) · 目录=\(chapters.count) 章")
        let source = sources.source(id: book.origin)
        let progress = library.item(for: book.id)?.lastChapterIndex ?? 0
        engineLog("[柴阅阅读器] 取到源=\(source?.bookSourceName ?? "(无)") · 轻阅进度章=\(progress)")
        let h = ChaiyueReaderHost(book: book,
                                  chapters: chapters,
                                  start: start,
                                  source: source,
                                  libraryItems: library.items,
                                  progressIndex: progress)
        // ⚠️ **先校验再挂上去**（挂上去就进 `if let host, let launch` 分支 ⇒ 兜底界面永远看不见）⭐⭐⭐
        // ⚠️ 用 `chaiyueBook`（两种模式都有）而不是 `launch`（漫画模式是 nil）⭐⭐⭐
        if h.chaiyueBook.name.isEmpty {
            errorText = "这本书的信息不完整（书名是空的）"
            return
        }
        host = h
        launch = h.launch
        engineLog("[柴阅阅读器] prepare 完成 · launch=\(h.launch == nil ? "nil(漫画)" : "有")")
    }

    // MARK: - 关闭

    @MainActor
    private func close() {
        // ⭐⭐⭐ 进度回写：柴阅写的是它自己的书架仓 ⇒ 轻阅的书库要手动搬回来 ⭐⭐⭐
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
