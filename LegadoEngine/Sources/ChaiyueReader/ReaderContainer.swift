import ChaiyueReaderKit
import ChaiyueModels
import ChaiyueReaderServices
import SwiftUI

/// 阅读器：开书动画 → 翻页区 + 菜单 → 合书动画
struct ReaderContainer: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    let launch: ReaderLaunch

    @State private var model: ReaderModel?
    @State private var progress: CGFloat = 0
    @State private var flight: CGRect?
    @State private var closing = false
    @State private var savedBrightness: CGFloat?

    /// 窗口安全区（容器忽略了安全区，GeometryReader 读不到）
    private var insets: EdgeInsets {
        let raw = AppearanceStore.keyWindow?.safeAreaInsets ?? UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        return EdgeInsets(top: raw.top, leading: raw.left, bottom: raw.bottom, trailing: raw.right)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.42 * progress)
                    .allowsHitTesting(false)
                if let model {
                    ReaderStage(model: model, size: size, insets: insets, close: close)
                        .modifier(PageFlight(progress: progress, origin: flight, size: size))
                        .allowsHitTesting(progress >= 1 && !closing)
                }
                if let flight, let model, progress < 1 {
                    CoverFlight(book: launch.book, back: model.theme.bg, progress: progress, origin: flight)
                        .allowsHitTesting(false)
                }
            }
        }
        .ignoresSafeArea()
        .onAppear(perform: start)
        .onChange(of: scheme) { _, new in model?.update(theme: app.settings.theme(for: new)) }
        .onChange(of: app.settings.lightTheme) { model?.update(theme: app.settings.theme(for: scheme)) }
        .onChange(of: app.settings.darkTheme) { model?.update(theme: app.settings.theme(for: scheme)) }
        .onChange(of: app.settings.customTheme) { model?.update(theme: app.settings.theme(for: scheme)) }
        .onChange(of: ReaderThemeStore.shared.revision) { model?.update(theme: app.settings.theme(for: scheme)) }
        .onChange(of: app.settings.brightness) { _, value in applyBrightness(value) }
        .onChange(of: app.contentSignal) { _, signal in
            guard let model, !closing, let signal, signal.sourceKey == model.book.origin else { return }
            model.retry(model.pointer.chapter)
        }
    }

    private var currentChapter: BookChapter? {
        guard let model else { return nil }
        let chapters = model.session.chapters
        return chapters.indices.contains(model.pointer.chapter) ? chapters[model.pointer.chapter] : nil
    }

    private func validFrame(_ rect: CGRect?) -> CGRect? {
        guard let rect, rect.width > 20, rect.height > 20 else { return nil }
        let screen = UIScreen.main.bounds
        return screen.intersects(rect) ? rect : nil
    }

    private func start() {
        guard model == nil else { return }
        let session = app.library.readerSession(for: launch.book)
        session.preloadCount = app.settings.preloadCount
        let model = ReaderModel(session: session, settings: app.settings, theme: app.settings.theme(for: scheme))
        self.model = model
        flight = validFrame(launch.origin)
        Task {
            await session.open()
            if app.mediaKind(of: session.book) != .text {
                app.openReader(session.book)
                app.closeReader()
                return
            }
            model.sessionOpened()
            app.library.callBack(.startRead, book: session.book, chapter: currentChapter)
            #if DEBUG
            if let chapter = DebugLaunch.flag("chapter").flatMap(Int.init) { model.jump(chapter: chapter) }
            #endif
        }
        withAnimation(.timingCurve(0.62, 0, 0.22, 1, duration: flight == nil ? 0.38 : 0.86)) {
            progress = 1
        }
        app.stats.begin()
        UIApplication.shared.isIdleTimerDisabled = app.settings.keepScreenOn
        applyBrightness(app.settings.brightness)
        #if DEBUG
        Task {
            try? await Task.sleep(for: .milliseconds(1400))
            if DebugLaunch.flag("readerMenu") != nil { withAnimation(.snappy) { model.menuVisible = true } }
            if let panel = DebugLaunch.flag("readerPanel").flatMap(ReaderPanel.init(rawValue:)) { model.panel = panel }
            if let turns = DebugLaunch.flag("autoTurn").flatMap(Int.init) {
                for _ in 0..<abs(turns) {
                    try? await Task.sleep(for: .milliseconds(1500))
                    model.onTurnRequest?(turns > 0)
                }
            }
            if DebugLaunch.flag("speak") != nil {
                for _ in 0..<60 where model.session.text(of: model.pointer.chapter) == nil {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                try? await Task.sleep(for: .seconds(1))
                if let text = model.session.text(of: model.pointer.chapter) {
                    ReaderSpeech.speak(app: app, model: model, text: text, from: 0)
                }
            }
        }
        #endif
    }

    private func applyBrightness(_ value: Double?) {
        let screen = UIScreen.main
        if let value {
            if savedBrightness == nil { savedBrightness = screen.brightness }
            screen.brightness = CGFloat(value)
        } else if let savedBrightness {
            screen.brightness = savedBrightness
            self.savedBrightness = nil
        }
    }

    private func close() {
        guard let model, !closing else { return }
        closing = true
        app.library.callBack(.endRead, book: model.session.book, chapter: currentChapter)
        model.panel = nil
        withAnimation(.snappy) { model.menuVisible = false }
        let key = launch.coverKey
        flight = validFrame(key.flatMap { app.coverFrames[$0] } ?? launch.origin)
        app.stats.end()
        UIApplication.shared.isIdleTimerDisabled = false
        if let savedBrightness { UIScreen.main.brightness = savedBrightness }
        let speaking = app.speech.state != .idle && app.speechBook?.bookUrl == model.book.bookUrl
        if !speaking {
            app.speechChapterFinished = nil
            model.commitVisiblePosition()
            model.session.close()
        }
        withAnimation(.timingCurve(0.5, 0, 0.2, 1, duration: flight == nil ? 0.28 : 0.72)) {
            progress = 0
        } completion: {
            app.closeReader()
        }
    }
}

// MARK: - 开书动画

/// 正文页从封面位置放大到全屏（原型 `.ofx-page`）
private struct PageFlight: ViewModifier, Animatable {
    var progress: CGFloat
    let origin: CGRect?
    let size: CGSize

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = min(max(progress, 0), 1)
        let scale: CGFloat
        let offset: CGSize
        let opacity: Double
        if let origin, size.height > 0 {
            let start = origin.height / size.height
            scale = start + (1 - start) * p
            offset = CGSize(width: origin.minX * (1 - p), height: origin.minY * (1 - p))
            opacity = 1
        } else {
            scale = 1.04 - 0.04 * p
            offset = .zero
            opacity = p
        }
        return content
            .overlay {
                LinearGradient(colors: [.black.opacity(0.38), .black.opacity(0.08), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .opacity(origin == nil ? 0 : Double(1 - p))
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: origin == nil ? 0 : 40 * (1 - p) / max(scale, 0.01), style: .continuous))
            .scaleEffect(scale, anchor: origin == nil ? .center : .topLeading)
            .offset(offset)
            .opacity(opacity)
    }
}

/// 封面绕左边缘翻开（原型 `.ofx-cover`），过半后显示封面内侧
private struct CoverFlight: View, Animatable {
    let book: Book
    let back: Color
    var progress: CGFloat
    let origin: CGRect

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let p = min(max(progress, 0), 1)
        let screen = UIScreen.main.bounds.size
        let end = screen.height / origin.height
        let scale = 1 + (end - 1) * p
        let angle = -165 * Double(p)
        let opacity = p < 0.6 ? 1 : max(0, Double(1 - p) / 0.4)
        let perspective = max(origin.width, origin.height) * scale / 1800
        ZStack {
            if angle > -90 {
                BookCover(book: book, maxPixel: 600)
            } else {
                LinearGradient(colors: [back.blend(with: .black, by: 0.22), back.blend(with: .black, by: 0.08)],
                               startPoint: .leading, endPoint: .trailing)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.coverRadius))
            }
        }
        .frame(width: origin.width, height: origin.height)
        .rotation3DEffect(.degrees(angle), axis: (0, 1, 0), anchor: .leading, perspective: perspective)
        .scaleEffect(scale, anchor: .topLeading)
        .offset(x: origin.minX * (1 - p), y: origin.minY * (1 - p))
        .opacity(opacity)
    }
}

// MARK: - 阅读区

struct ReaderStage: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: ReaderModel
    let size: CGSize
    let insets: EdgeInsets
    let close: () -> Void

    var body: some View {
        let theme = model.theme
        ZStack {
            theme.bg
            stage
            ReaderChrome(model: model, insets: insets, close: close)
            if model.panel == .style {
                // 排版面板不压暗正文以便实时预览，点面板外空白处收起
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.panel = nil }
            }
        }
        .frame(width: size.width, height: size.height)
        .statusBarHidden(!model.menuVisible)
        .persistentSystemOverlays(model.menuVisible ? .automatic : .hidden)
        .onAppear {
            model.update(metrics: currentMetrics(size))
            model.onTextAction = { [weak app, weak model] action, pick in
                guard let app, let model else { return }
                ReaderTextActions.perform(action, pick, app: app, model: model)
            }
            model.onNotice = { [weak app] message in app?.island.show("exclamationmark.bubble", message, danger: true) }
        }
        .onChange(of: size) { _, new in model.update(metrics: currentMetrics(new)) }
        .onChange(of: model.session.chapterStates) { model.chaptersChanged() }
        .onChange(of: model.theme.style?.page) { model.update(metrics: currentMetrics(size)) }
        .onChange(of: typographyKey) {
            model.update(metrics: currentMetrics(size))
            model.typographyChanged()
        }
        .sheet(item: $model.panel) { panel in
            switch panel {
            case .toc:
                ReaderTocPanel(model: model)
            case .style:
                StylePanel(model: model)
            }
        }
    }

    private var typographyKey: String {
        let s = app.settings
        let fonts = FontLibrary.shared
        return "\(s.fontSize)|\(s.font.rawValue)|\(s.importedFont?.id ?? "-")|\(s.spacing)|\(fonts.songtiReady)|\(fonts.kaitiReady)"
            + "|\(s.paragraphComments)|\(s.pageStyle == .vertical)"
    }

    private func currentMetrics(_ size: CGSize) -> PageMetrics {
        Self.metrics(size: size, insets: insets, fontSize: app.settings.fontSize, page: model.theme.style?.page)
    }

    /// 原型版式：页眉在安全区顶，正文距页眉 30，页脚贴着 Home 条上方。
    /// 翻页模式每页末行贴齐文字区底边（竖向对齐），末行字形底边离区底约 0.24 字号，
    /// 据此让末行到页脚数字的空隙与页眉到首行的空隙一样（约 25pt）。
    /// 自定义主题的 `.page { padding }` 依次是页眉到正文、右边距、正文到页脚、左边距
    static func metrics(size: CGSize, insets: EdgeInsets, fontSize: Double, page: ReaderPageBox? = nil) -> PageMetrics {
        let top = max(insets.top, 24)
        let bottom = max(insets.bottom, 12)
        let left = CGFloat(min(max(page?.paddingLeft ?? 26, 0), size.width / 3))
        let right = CGFloat(min(max(page?.paddingRight ?? 26, 0), size.width / 3))
        let textTop = top + CGFloat(max(page?.paddingTop ?? 30, 0))
        let footerY = size.height - bottom - 14
        let gap = CGFloat(max(page?.paddingBottom ?? 25, 0))
        let textBottom = footerY + 2.3 - gap + 0.24 * CGFloat(fontSize)
        return PageMetrics(size: size,
                           textFrame: CGRect(x: left, y: textTop, width: size.width - left - right, height: max(100, textBottom - textTop)),
                           headerY: top,
                           footerY: footerY)
    }

    @ViewBuilder
    private var stage: some View {
        let session = model.session
        if session.chapters.isEmpty {
            TocPlaceholder(model: model, close: close)
        } else if model.theme.web {
            WebReaderView(model: model, version: model.version, size: size, insets: insets,
                          menuVisible: model.menuVisible, onCenterTap: toggleMenu)
                .id(model.theme.customID)
        } else if app.settings.pageStyle == .vertical {
            VerticalReaderView(model: model, version: model.version, onCenterTap: toggleMenu)
        } else {
            PagerView(model: model, style: app.settings.pageStyle, version: model.version, onCenterTap: toggleMenu)
        }
    }

    private func toggleMenu() {
        withAnimation(model.menuVisible ? .easeIn(duration: 0.2) : .snappy) {
            model.menuVisible.toggle()
        }
    }
}

/// 目录加载中或失败
private struct TocPlaceholder: View {
    @Environment(AppModel.self) private var app
    let model: ReaderModel
    let close: () -> Void

    var body: some View {
        let theme = model.theme
        VStack(spacing: 18) {
            Text(model.book.name.withoutEmoji)
                .font(.serif(24))
                .foregroundStyle(theme.fg)
            switch model.session.tocState {
            case .failed(let message):
                Text(message)
                    .font(.ui(14))
                    .foregroundStyle(theme.fg2)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(.horizontal, 40)
                HStack(spacing: 12) {
                    Button("返回", action: close)
                        .buttonStyle(.press)
                        .font(.ui(15, .medium))
                        .foregroundStyle(theme.fg)
                        .frame(width: 96, height: 44)
                        .background(theme.fg.opacity(0.08), in: Capsule())
                    Button {
                        Task {
                            await model.session.refreshToc()
                            model.sessionOpened()
                        }
                    } label: {
                        Text("重试").font(.ui(15, .semibold)).foregroundStyle(Tok.onAccent)
                            .frame(width: 96, height: 44)
                            .background(Tok.accent, in: Capsule())
                    }
                    .buttonStyle(.press)
                }
            case .ready:
                Text("没有章节").font(.ui(14)).foregroundStyle(theme.fg2)
                Button("返回", action: close)
                    .font(.ui(15, .medium))
                    .foregroundStyle(theme.fg)
                    .frame(width: 96, height: 44)
                    .background(theme.fg.opacity(0.08), in: Capsule())
                    .buttonStyle(.press)
            default:
                ProgressView().tint(theme.fg2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}
