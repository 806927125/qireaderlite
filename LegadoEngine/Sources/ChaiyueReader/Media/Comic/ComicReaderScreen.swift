#if os(iOS)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Media/Comic/ComicReaderScreen.swift 搬运**（2026-11-26 · 柴阅漫画阅读器 vendor）⭐⭐⭐⭐⭐
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Media/Comic/ComicReaderScreen.swift
//
// ⚠️⚠️ **与上游的 diff**（只有这些，其余一字未改）⭐⭐⭐：
//   ① `import ReaderModels` → `import ChaiyueModels`、`import ReaderServices` → `import ChaiyueReaderServices`
//      （模块改名，与本仓库其它 vendor 文件一致）⭐⭐⭐
//   ② 整文件包进 `#if os(iOS)`（漫画阅读器用满 UIKit ⇒ macOS/Linux 编不到 ⇒ 与本仓库其它 iOS 界面件一致）⭐⭐⭐
//   ③ `MediaKindStyle.swift` 里 `BookMediaKind` 的三个成员升 public（宿主要用「漫画」角标与「开始看漫画」文案）⭐⭐⭐
import ChaiyueModels
import SwiftUI

/// 漫画阅读页（设计稿 design/media-players.html「漫画」）
///
/// ⭐⭐⭐⭐⭐ **【改造】升 public**（2026-11-26 · 柴阅漫画阅读器 vendor）⭐⭐⭐⭐⭐
///   宿主 App 要开它 ⇒ 跨模块 ⇒ 必须 public（`public struct` 的默认 memberwise init 也是 internal
///   ⇒ 还要显式写 `public init`）⭐⭐⭐
public struct ComicReaderScreen: View {
    @Environment(AppModel.self) private var app
    public let launch: MediaLaunch

    /// ⭐⭐⭐ **宿主要 new 它** ⇒ 显式 public init（memberwise init 是 internal ⇒ 宿主编不过）⭐⭐⭐
    public init(launch: MediaLaunch) {
        self.launch = launch
    }

    @State private var model: ComicModel?
    @State private var progress: CGFloat = 0
    @State private var flight: CGRect?
    @State private var drag: CGFloat = 0
    @State private var closing = false
    @State private var savedBrightness: CGFloat?

    private var insets: EdgeInsets {
        let raw = AppearanceStore.keyWindow?.safeAreaInsets ?? UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        return EdgeInsets(top: raw.top, leading: raw.left, bottom: raw.bottom, trailing: raw.right)
    }

    public var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let pulled = min(1, drag / max(size.width, 1))
            ZStack {
                Color.black.opacity(0.42 * progress * (1 - pulled))
                    .allowsHitTesting(false)
                if let model {
                    ComicContent(model: model, insets: insets, close: close,
                                 onEdgeDrag: { drag = $0 },
                                 onEdgeEnd: { dx, velocity in edgeEnded(dx, velocity, width: size.width) },
                                 setBrightness: setBrightness)
                        .frame(width: size.width, height: size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 44 * min(1, drag / 60), style: .continuous))
                        .scaleEffect(1 - 0.08 * pulled)
                        .offset(x: drag)
                        .modifier(ComicFlight(progress: progress, origin: flight, size: size, book: launch.book))
                        .allowsHitTesting(progress >= 1 && !closing)
                }
            }
        }
        .ignoresSafeArea()
        .onAppear(perform: start)
    }

    private func validFrame(_ rect: CGRect?) -> CGRect? {
        guard let rect, rect.width > 20, rect.height > 20 else { return nil }
        return UIScreen.main.bounds.intersects(rect) ? rect : nil
    }

    private func start() {
        guard model == nil else { return }
        let model = ComicModel(session: app.library.mediaSession(for: launch.book))
        self.model = model
        flight = validFrame(launch.origin)
        Task { await model.start() }
        withAnimation(.timingCurve(0.62, 0, 0.22, 1, duration: flight == nil ? 0.38 : 0.72)) {
            progress = 1
        }
        UIApplication.shared.isIdleTimerDisabled = app.settings.keepScreenOn
    }

    private func edgeEnded(_ dx: CGFloat, _ velocity: CGFloat, width: CGFloat) {
        if velocity >= 0, dx > width * 0.32 || velocity > 700 {
            close()
        } else {
            withAnimation(.snappy) { drag = 0 }
        }
    }

    private func setBrightness(_ value: Double) {
        if savedBrightness == nil { savedBrightness = UIScreen.main.brightness }
        UIScreen.main.brightness = CGFloat(value)
    }

    private func close() {
        guard let model, !closing else { return }
        closing = true
        withAnimation(.snappy) { model.menuVisible = false }
        model.close()
        UIApplication.shared.isIdleTimerDisabled = false
        if let savedBrightness { UIScreen.main.brightness = savedBrightness }
        withAnimation(.timingCurve(0.5, 0, 0.2, 1, duration: flight == nil ? 0.28 : 0.6)) {
            progress = 0
            drag = 0
        } completion: {
            app.closeMedia()
        }
    }
}

// MARK: - 打开动画

/// 从封面位置放大成全屏：裁切框从封面框长到全屏，内容等比铺满裁切框，封面在前半程淡出
private struct ComicFlight: ViewModifier, Animatable {
    var progress: CGFloat
    let origin: CGRect?
    let size: CGSize
    let book: Book

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = min(max(progress, 0), 1)
        if let origin, size.width > 0, size.height > 0 {
            let rect = CGRect(x: origin.minX * (1 - p), y: origin.minY * (1 - p),
                              width: origin.width + (size.width - origin.width) * p,
                              height: origin.height + (size.height - origin.height) * p)
            let fill = max(origin.width / size.width, origin.height / size.height)
            let scale = fill + (1 - fill) * p
            let radius = p >= 1 ? 0 : Metrics.coverRadius + (44 - Metrics.coverRadius) * p
            content
                .scaleEffect(scale)
                .frame(width: rect.width, height: rect.height)
                .overlay {
                    if p < 0.5 {
                        BookCover(book: book, maxPixel: 600)
                            .frame(width: rect.width, height: rect.height)
                            .opacity(Double(1 - p / 0.5))
                            .allowsHitTesting(false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .position(x: rect.midX, y: rect.midY)
        } else {
            content
                .scaleEffect(0.94 + 0.06 * p)
                .opacity(Double(p))
        }
    }
}

// MARK: - 阅读区

private struct ComicContent: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: ComicModel
    let insets: EdgeInsets
    let close: () -> Void
    let onEdgeDrag: (CGFloat) -> Void
    let onEdgeEnd: (CGFloat, CGFloat) -> Void
    let setBrightness: (Double) -> Void

    @State private var showingToc = false

    var body: some View {
        ZStack {
            Tok.bg
            if model.isReady {
                ComicStage(model: model, mode: model.mode, onCenterTap: toggleMenu, onEdgeDrag: onEdgeDrag, onEdgeEnd: onEdgeEnd)
                    .id("\(model.mode.rawValue)-\(model.generation)")
                    .transition(.opacity)
            } else {
                ComicPlaceholder(model: model, close: close)
                    .onTapGesture(perform: toggleMenu)
                    .transition(.opacity)
            }
            ComicChrome(model: model, insets: insets, close: close, showingToc: $showingToc, setBrightness: setBrightness)
        }
        .animation(.easeInOut(duration: 0.24), value: model.isReady)
        .animation(.easeInOut(duration: 0.24), value: model.mode)
        .statusBarHidden(!model.menuVisible)
        .persistentSystemOverlays(model.menuVisible ? .automatic : .hidden)
        .sheet(isPresented: $showingToc) {
            let session = model.session
            TocSheet(chapters: session.chapters, current: model.current.chapter, bookUrl: model.book.bookUrl,
                     state: session.tocState,
                     onRetry: { Task { await model.retryToc() } },
                     onPick: { index in
                         showingToc = false
                         model.menuVisible = false
                         model.jump(chapter: index)
                     })
                .qSheet([.fraction(0.76), .large])
                .environment(app)
        }
    }

    private func toggleMenu() {
        withAnimation(model.menuVisible ? .easeIn(duration: 0.2) : .snappy) {
            model.menuVisible.toggle()
        }
    }
}

/// 目录或本章加载中、失败
private struct ComicPlaceholder: View {
    let model: ComicModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            if let message {
                Text(message)
                    .font(.ui(14))
                    .foregroundStyle(Tok.fg2)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(.horizontal, 40)
                HStack(spacing: 12) {
                    Button(action: close) {
                        Text("返回").font(.ui(15, .medium)).foregroundStyle(Tok.fg)
                            .frame(width: 96, height: 44)
                            .background(Tok.fill2, in: Capsule())
                    }
                    .buttonStyle(.press)
                    if canRetry {
                        Button(action: retry) {
                            Text("重试").font(.ui(15, .semibold)).foregroundStyle(Tok.onAccent)
                                .frame(width: 96, height: 44)
                                .background(Tok.accent, in: Capsule())
                        }
                        .buttonStyle(.press)
                    }
                }
            } else {
                ProgressView().tint(Tok.fg3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private var message: String? {
        let session = model.session
        switch session.tocState {
        case .failed(let text): return text
        case .ready where session.chapters.isEmpty: return "没有章节"
        case .ready:
            if case .failed(let text) = model.chapters[model.current.chapter] { return text }
            return nil
        default: return nil
        }
    }

    private var canRetry: Bool {
        if case .ready = model.session.tocState { return !model.session.chapters.isEmpty }
        return true
    }

    private func retry() {
        if case .failed = model.session.tocState {
            Task { await model.retryToc() }
        } else {
            model.jump(chapter: model.current.chapter, page: model.current.page)
        }
    }
}

#endif  // #if os(iOS)
