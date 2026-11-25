import SwiftUI

@main
struct QiReaderLiteApp: App {
    @StateObject private var sources = SourceStore()
    /// ⭐⭐⭐ 浏览器入口（引擎 → 主线程 → SwiftUI 的桥梁）⭐⭐⭐
    @StateObject private var browserPresenter = BrowserPresenter.shared
    @StateObject private var library = LibraryStore()
    /// 液态玻璃浓度（用户可调）—— 0 最透，1 最实
    @AppStorage(GlassTintStore.key) private var glassTintPercent: Double = 45

    init() {
        // ⭐⭐⭐ **build252：老 JS 引擎（WKWebView）退役**（用户明确要求：「老引擎给我去掉先」）
        //   · 现在**只有一个引擎**（新 Swift 引擎 `legado-engine`）⇒ 没有开关、没有回退
        //   · 旧的一次性迁移键（曾把主链路强制切回老引擎）⇒ **彻底清掉**（否则会一直把开关写回 false）⭐⭐⭐
        // ⭐⭐⭐ 引擎日志出口挂上面板（诊断要用户「复制日志」就能看到 ⇒ 不用去 Xcode 看控制台）
        EngineLogBootstrap.install()
        // ⭐⭐⭐⭐⭐ **装上柴阅的界面委托**（2026-11-21 移植柴阅的登录配套设施）⭐⭐⭐
        //   ⇒ 柴阅的引擎把「浏览器 / 验证码 / 后台渲染 / toast」交给宿主 ⭐⭐⭐
        //   ⇒ 不装 ⇒ 站方登录要开浏览器/要验证码 ⇒ **静默失败**（此前就是这样）⭐⭐⭐
        //   ⇒ 聚合源的「🍅番茄登录 / 🔐注册书源 / 🏝用户后台」全是浏览器流程 ⭐⭐⭐
        // ⚠️⚠️ **`init()` 不是 MainActor 隔离的** ⇒ 用 Task 切主线程 ⭐⭐⭐
        Task { @MainActor in ChaiyueRuntime.installUI() }
        // ⭐⭐⭐⭐⭐ **每次启动都报一次 build 号**（2026-10-28 教训）
        //   ⇒ 用户反馈「还是一样」时，**第一件事就是确认他装的到底是哪一版**
        //   ⇒ 之前就是因为跑的是 build271（没有探针的版本）⇒ 白猜了好几轮 ⇒
        //   ⇒ 现在日志第一行就有版本号 ⇒ 不用再靠猜
        let bv = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        engineLog("[轻阅] 本机版本 = build \(bv)（\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")）")
        UserDefaults.standard.removeObject(forKey: "qr.useNewEngine")
        UserDefaults.standard.removeObject(forKey: "qr.fallbackLegacy")
        UserDefaults.standard.removeObject(forKey: "qr.engine.legacy240")
        // ⭐⭐⭐⭐⭐ **玻璃白纱：把「旧默认 45」一次性对齐到新皮肤（2026-11-24 星澜终端）** ⭐⭐⭐⭐⭐
        //   ⇒ 旧默认 45 = 浅色底上的「乳白玻璃」⇒ 换深色底后 38% 白纱会把玻璃糊成一片白 ⭐⭐⭐
        //   ⇒ **只改「等于旧默认」的那一档**（用户自己调过的不动）⇒ 零打扰 ⭐⭐⭐
        if GlassTintStore.percent == 45 { GlassTintStore.percent = 8 }
        // ⭐⭐⭐⭐⭐ **阅读排版默认值对齐柴阅**（2026-11-25）⭐⭐⭐⭐⭐
        //   · 字号 18→20 · 行距 8→11（0.55×）· 段距 10→14（0.7×）· 对齐 左→两端
        //   ⇒ **只改「等于旧默认」的那一档** ⇒ 用户自己调过的不动 ⇒ 零打扰 ⭐⭐⭐
        let d = UserDefaults.standard
        if d.object(forKey: "reader.fontSize") == nil || d.double(forKey: "reader.fontSize") == 18 { d.set(20.0, forKey: "reader.fontSize") }
        if d.object(forKey: "reader.lineSpacing") == nil || d.double(forKey: "reader.lineSpacing") == 8 { d.set(11.0, forKey: "reader.lineSpacing") }
        if d.object(forKey: "reader.paraSpacing") == nil || d.double(forKey: "reader.paraSpacing") == 10 { d.set(14.0, forKey: "reader.paraSpacing") }
        if d.object(forKey: "reader.paraAlign") == nil || d.string(forKey: "reader.paraAlign") == "left" { d.set("justify", forKey: "reader.paraAlign") }
        // ⭐⭐⭐ **日志出口挂上**（诊断要能进「引擎日志」面板 ⇒ 用户直接看到）⭐⭐⭐
        //   ⚠️⚠️ 之前这里又赋了一次 sink ⇒ **覆盖掉** `EngineLogBootstrap.install()` 里
        //   那个 `Task { @MainActor in … }` 的版本 ⇒ 后台线程直接改 @Published 状态
        //   ⇒ UI 在后台线程更新 ⇒ 闪退风险 ⭐⭐⭐
        //   ⇒ 现在**只由 EngineLogBootstrap 挂一次**（它负责切主线程）⭐⭐⭐
        // ⭐⭐⭐ 2026-11-19：老引擎（WebView JS + 自研 Swift）**全部退役**
        //   ⇒ 引擎 = **柴阅/Chaiyue**（vendor 进本仓库；语义 = Legado 3.0；模块名保留 LegadoEngine）
        //   ⇒ **没有 JS 后端要装、也没有引擎沙盒要起** ⭐⭐⭐
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // ⭐⭐⭐⭐⭐ **强制深色外观**（2026-11-24 星澜终端真机反馈：「这些按钮太白了」）⭐⭐⭐⭐⭐
                //   ⇒ **症状**：下拉菜单 / 筛选胶囊 / 标签栏 / 分类筛选页的按钮 / 阅读页底部面板
                //     **全是乳白色**（深空底上像一排白板）⭐⭐⭐
                //   ⇒ **根因**：那些是**系统玻璃**（iOS 26 的 `.glassEffect`）⇒ **系统按「当前外观」渲染** ⭐⭐⭐
                //     ⇒ App 以前**从来没强制过外观** ⇒ 跟系统走（浅色）⇒ 系统玻璃出乳白 ⭐⭐⭐
                //   ⇒ **正解**：**根部强制 `.dark`** ⇒ 一处 ⇒ 所有系统玻璃/菜单/弹窗/搜索框
                //     全都切到**深色玻璃** ⇒ 跟深空底融在一起 ⭐⭐⭐⭐⭐
                //   ⇒ ⚠️ **阅读正文不受影响**：纸色主题是**写死的颜色** ⇒ 照旧；只有「跟随系统」那一档会变深 ⭐⭐⭐
                .preferredColorScheme(.dark)
                .environmentObject(sources)
                .environmentObject(library)
                // ⭐⭐⭐ **文件 / 分享进来的书源**（2026-10-26）
                //   ⇒ 以前**没有这个入口** ⇒ 文件送进来了没人接 ⇒ 静默无反应（「选中打不开」）⭐⭐⭐
                .onOpenURL { url in
                    Task { @MainActor in
                        do {
                            let st = try SourceFileImport.importFile(url, into: sources)
                            // ⭐⭐⭐ **说清「新增/更新/未变」**（旧版只报新增个数 ⇒ 更新时显示 0）⭐⭐⭐
                            Toast.show("从文件导入完成：\(st.summary)")
                        } catch {
                            Toast.show("导入失败：\(error.localizedDescription)")
                        }
                    }
                }
                // 玻璃浓度注入 environment → 全站 25 处玻璃调用点自动跟随
                // （0 = 纯玻璃，0.85 = 乳白玻璃 ≈ 栖阅的 rgba(255,255,255,.82)）
                .environment(\.glassTint, glassTintPercent / 100 * GlassTintStore.maxVeil)
                // ⭐⭐⭐⭐⭐ **浏览器入口**（2026-11-21 移植柴阅的登录配套设施）⭐⭐⭐
                //   ⇒ 柴阅的引擎（站方 `java.startBrowser` / `startBrowserAwait`）要开浏览器 ⭐⭐⭐
                //   ⇒ 它把请求交给 `ChaiyueInteractionPresenter` ⇒ 那里弹这个 sheet ⭐⭐⭐
                //   ⇒ **轻阅的 `BrowserSheet` 早就写好了**（注释里就写着给这个用）⇒ 现在接上 ⭐⭐⭐
                .sheet(item: $browserPresenter.item) { item in
                    BrowserSheet(url: item.url, title: item.title, onFinish: item.onFinish)
                }
        }
    }
}

// MARK: - 主题

// ⭐⭐⭐⭐⭐ **「星澜终端」配色**（2026-11-24 按 HTML 原型换肤）⭐⭐⭐⭐⭐
//
// ⚠️⚠️⚠️ **为什么改这里就等于「全 App 换肤」** ⭐⭐⭐
//   所有页面的配色都走 `Theme.xxx` ⇒ ⇒ **只改这一处常量** ⇒ 全 App 一次变深空玻璃 ⭐⭐⭐
//   ⇒ **不要去各个页面里手改颜色**（会漂、且下次换肤又要改一遍）⭐⭐⭐
enum Theme {
    /// 页面底色（深空 #070912）
    static let bg = Terminal.bg
    /// 卡片底（玻璃）
    static let card = Terminal.glass
    /// 主文字（#eef2ff）
    static let ink = Terminal.ink
    /// 次级文字
    static let sub = Terminal.dim
    /// 主强调色（青 #7dd3fc）
    static let accent = Terminal.cyan
    /// 分隔线（白描边）
    static let line = Terminal.edge
}

extension View {
    /// 统一的卡片外观，全局收口一处
    func cardStyle(padding: CGFloat = 12) -> some View {
        self
            .padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            // ⭐⭐⭐ **深色底上卡片要有一圈描边**，否则玻璃的边界看不出来（浅色底上靠阴影就够）⭐⭐⭐
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Theme.line, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 4)
    }
}

/// 远程封面：自己缓存，别指望 URLSession 的默认缓存
struct CoverImage: View {
    let url: String
    var width: CGFloat = 64
    var height: CGFloat = 88

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.sub.opacity(0.12))
            if let img = image {
                Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
            } else if failed {
                Image(systemName: "book.closed")
                    .font(.system(size: width * 0.34))
                    .foregroundStyle(Theme.sub.opacity(0.5))
            } else {
                ProgressView().scaleEffect(0.6)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: url) { await load() }
    }

    private func load() async {
        // ⭐⭐⭐⭐⭐ **站方的封面 URL 带 `,{…}` 后缀（请求头）⇒ 必须拆开 + 带头请求**
        //   ⇒ 不拆 ⇒ 后缀被百分号编码（`%7B`）⇒ 拆不出来 ⇒ 404 / CDN 403 ⇒ **占位图** ⭐⭐⭐
        guard let req = AnalyzeUrl.request(url) else {
            engineLog("[封面] URL 解析失败：\(String(url.prefix(120)))")
            failed = true; return
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            engineLog("[封面] \(req.url?.absoluteString ?? "") 状态=\(code) 字节=\(data.count)")
            guard let img = UIImage(data: data), code == 200 else { failed = true; return }
            await MainActor.run { image = img; failed = false }
        } catch {
            engineLog("[封面] 请求失败：\(String(error.localizedDescription.prefix(80)))")
            failed = true
        }
    }
}

// MARK: - 通用状态视图

struct EmptyHint: View {
    let icon: String
    let title: String
    var subtitle: String = ""

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(Theme.sub.opacity(0.6))
            Text(title).font(.headline).foregroundStyle(Theme.ink)
            if !subtitle.isEmpty {
                Text(subtitle).font(.subheadline).foregroundStyle(Theme.sub)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorHint: View {
    let message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 34)).foregroundStyle(.orange)
            Text(message).font(.subheadline).foregroundStyle(Theme.sub)
                .multilineTextAlignment(.center).padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
