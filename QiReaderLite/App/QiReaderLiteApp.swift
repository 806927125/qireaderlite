import SwiftUI
import LegadoCore

@main
struct QiReaderLiteApp: App {
    @StateObject private var sources = SourceStore()
    @StateObject private var library = LibraryStore()
    /// 液态玻璃浓度（用户可调）—— 0 最透，1 最实
    @AppStorage(GlassTintStore.key) private var glassTintPercent: Double = 45

    init() {
        // ⭐⭐⭐ **build252：老 JS 引擎（WKWebView）退役**（用户明确要求：「老引擎给我去掉先」）
        //   · 现在**只有一个引擎**（新 Swift 引擎 `legado-engine`）⇒ 没有开关、没有回退
        //   · 旧的一次性迁移键（曾把主链路强制切回老引擎）⇒ **彻底清掉**（否则会一直把开关写回 false）⭐⭐⭐
        UserDefaults.standard.removeObject(forKey: "qr.useNewEngine")
        UserDefaults.standard.removeObject(forKey: "qr.fallbackLegacy")
        UserDefaults.standard.removeObject(forKey: "qr.engine.legacy240")
        // 引擎沙盒尽早起来，首个界面就要用到
        Task { @MainActor in
            RuleSandbox.shared.boot()
            // ⭐⭐⭐⭐⭐ **JS 后端**（2026-10-26）：站方 JS 跑在 WKWebView 的**独立进程**（跟老引擎一样）
            Self.installJSBackend()
        }
    }

    /// ⭐⭐⭐⭐⭐ **装 JS 后端**（Core 不能 import WebKit ⇒ 由这里注册实现）
    @MainActor
    static func installJSBackend() {
        let raw = UserDefaults.standard.string(forKey: JSEngineFactory.Kind.storageKey)
            ?? JSEngineFactory.Kind.webView.storageValue
        let kind = JSEngineFactory.Kind(storageValue: raw) ?? .webView
        JSEngineFactory.setKind(kind)
        switch kind {
        case .webView:
            // ⭐ 站方 JS 跑在 **WebContent 独立进程** ⇒ 它吃多少内存都炸不到 App
            WebViewJSHost.shared.boot()
            // ⭐ 同步通道装一次（老引擎同款：JS 用 prompt 同步问原生）
            WebViewJSHost.shared.syncHandler = { payload in
                WebViewJSBridge.shared.handleSync(payload)
            }
            JSEngineFactory.install { api in WebViewJSExecutor(api: api) }
        case .jsc:
            // ⚠️ 跑在 **App 进程内** ⇒ 站方脚本的内存算我们的 ⇒ 有闪退风险（留作对照）
            JSEngineFactory.install { api in
                #if canImport(JavaScriptCore)
                return JSCExecutor(api: api)
                #else
                return nil
                #endif
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(sources)
                .environmentObject(library)
                // 玻璃浓度注入 environment → 全站 25 处玻璃调用点自动跟随
                // （0 = 纯玻璃，0.85 = 乳白玻璃 ≈ 栖阅的 rgba(255,255,255,.82)）
                .environment(\.glassTint, glassTintPercent / 100 * GlassTintStore.maxVeil)
                .task { RuleSandbox.shared.boot() }
        }
    }
}

// MARK: - 主题

enum Theme {
    static let bg = Color(red: 0.949, green: 0.961, blue: 0.969)
    static let card = Color.white
    static let ink = Color(red: 0.13, green: 0.15, blue: 0.20)
    static let sub = Color(red: 0.45, green: 0.48, blue: 0.54)
    static let accent = Color(red: 0.310, green: 0.478, blue: 0.851)
    static let line = Color.black.opacity(0.07)
}

extension View {
    /// 统一的卡片外观，全局收口一处
    func cardStyle(padding: CGFloat = 12) -> some View {
        self
            .padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 6, x: 0, y: 2)
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
        guard let s = url.isEmpty ? nil : URL(string: url),
              let (data, _) = try? await URLSession.shared.data(from: s),
              let img = UIImage(data: data) else { failed = true; return }
        await MainActor.run { image = img; failed = false }
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
