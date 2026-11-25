// ⭐⭐⭐⭐⭐ **平台条件编译补丁**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **为什么需要**：阅读器界面用满 UIKit（`UIScreen` / `UIApplication` / `UIImpactFeedbackGenerator` …）
//   ⇒ **iOS-only** ⇒ Linux 沙盒编不到 SwiftUI/UIKit ⇒ 若不隔离，**整个包的 Linux 编译门禁全废** ⭐⭐⭐
//   ⇒ 用 `#if canImport(UIKit)` 包裹：**Apple 平台功能完全不变**，Linux 上跳过这段界面代码 ⭐⭐⭐
//   ⇒ 与上游的 diff 仅此两行（去掉即可回到柴阅原样）⭐⭐⭐
#if canImport(SwiftUI)
import ChaiyueReaderKit
import SwiftUI

/// 排版面板（原型 `.sheet-style`）：亮度、字号、行距、字体、主题、翻页方式
struct StylePanel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    let model: ReaderModel

    @State private var brightness: Double = Double(UIScreen.main.brightness)

    var body: some View {
        @Bindable var settings = app.settings
        VStack(spacing: 18) {
            brightnessRow
            HStack(spacing: 10) {
                sizeStepper
                SpacingPicker(selection: $settings.spacing)
            }
            FontPicker()
            themeRow
            modeRow
        }
        .padding(.horizontal, 20)
        .padding(.top, 26)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(548)])
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled)
        .modifier(PanelBackground())
        .onAppear {
            if let value = app.settings.brightness { brightness = value }
        }
    }

    // MARK: - 亮度

    private var brightnessRow: some View {
        HStack(spacing: 14) {
            Image(icon: "sun.min").font(.system(size: 15)).foregroundStyle(Tok.gFg2)
            GlassSlider(value: $brightness, range: 0.05...1) { value in
                app.settings.brightness = value
            }
            Image(icon: "sun.max").font(.system(size: 20)).foregroundStyle(Tok.gFg2)
        }
        .frame(height: 30)
    }

    // MARK: - 字号

    private var sizeStepper: some View {
        @Bindable var settings = app.settings
        return FontSizeStepper(size: $settings.fontSize)
    }

    // MARK: - 主题

    private var themeRow: some View {
        let current = model.theme.id
        return ThemeStrip(current: current) { theme, origin in pick(theme, origin: origin) }
            .padding(.horizontal, -20)
    }

    private func pick(_ theme: ReaderThemeSpec, origin: CGPoint) {
        guard theme.id != model.theme.id else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        let wantsDark = theme.isDark
        if wantsDark != (scheme == .dark) {
            app.settings.select(theme)
            app.appearance.force(wantsDark ? .dark : .light, origin: origin)
        } else if let window = AppearanceStore.keyWindow, !UIAccessibility.isReduceMotionEnabled {
            CircularReveal.perform(in: window, origin: origin) { app.settings.select(theme) }
        } else {
            app.settings.select(theme)
        }
    }

    // MARK: - 翻页方式

    private var modeRow: some View {
        HStack(spacing: 0) {
            ForEach(PageTurnStyle.ordered, id: \.self) { style in
                ModeCard(style: style, selected: app.settings.pageStyle == style, theme: model.theme) {
                    guard app.settings.pageStyle != style else { return }
                    UISelectionFeedbackGenerator().selectionChanged()
                    app.settings.pageStyle = style
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct PanelBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
        } else {
            content
                .presentationBackground(.regularMaterial)
                .presentationCornerRadius(38)
        }
    }
}

// MARK: - 组件

/// 细轨滑块：拖动时圆钮放大
struct GlassSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onChange: ((Double) -> Void)?

    @State private var dragging = false
    /// 拖动起点的值；nil 表示还没判定方向，竖向拖动（下拉面板）不改值
    @State private var start: Double?
    @State private var horizontal: Bool?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let knob: CGFloat = dragging ? 26 : 22
            let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            ZStack(alignment: .leading) {
                Capsule().fill(Tok.gFill2).frame(height: 6)
                Capsule().fill(Tok.gFg.opacity(0.8)).frame(width: max(6, fraction * width), height: 6)
                Circle()
                    .fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                    .offset(x: fraction * (width - knob))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { gesture in
                        let t = gesture.translation
                        if horizontal == nil {
                            horizontal = abs(t.width) > abs(t.height)
                            start = value
                        }
                        guard horizontal == true, let start else { return }
                        if !dragging { withAnimation(.snappy) { dragging = true } }
                        let span = range.upperBound - range.lowerBound
                        let moved = start + Double(t.width / max(width - knob, 1)) * span
                        value = min(max(moved, range.lowerBound), range.upperBound)
                        onChange?(value)
                    }
                    .onEnded { _ in
                        horizontal = nil
                        start = nil
                        withAnimation(.snappy) { dragging = false }
                    }
            )
        }
    }
}

/// 字号步进：14–30
struct FontSizeStepper: View {
    @Binding var size: Double

    var body: some View {
        let value = Int(size)
        HStack(spacing: 0) {
            Button { step(-1) } label: {
                Text("A").font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.press)
            .disabled(value <= 14)
            Text("\(value)")
                .font(.num(17, .semibold))
                .contentTransition(.numericText(value: Double(value)))
                .frame(width: 36)
            Button { step(1) } label: {
                Text("A").font(.system(size: 21, weight: .medium))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.press)
            .disabled(value >= 30)
        }
        .foregroundStyle(Tok.gFg)
        .frame(height: 46)
        .background(Tok.gFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func step(_ delta: Double) {
        let next = min(30, max(14, size + delta))
        guard next != size else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.snappy) { size = next }
    }
}

/// 行距三档
struct SpacingPicker: View {
    @Binding var selection: Int
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { level in
                Button {
                    guard selection != level else { return }
                    UISelectionFeedbackGenerator().selectionChanged()
                    withAnimation(.snappy) { selection = level }
                } label: {
                    SpacingGlyph(level: level)
                        .stroke(Tok.gFg, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        .frame(width: 20, height: 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            if selection == level {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Tok.segBg)
                                    .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
                                    .matchedGeometryEffect(id: "spacing", in: ns)
                                    .padding(3)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 46)
        .background(Tok.gFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

nonisolated struct SpacingGlyph: Shape {
    let level: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let gaps: [CGFloat] = [3.2, 4.6, 6.2]
        let gap = gaps[min(max(level, 0), 2)]
        let count = 4
        let total = gap * CGFloat(count - 1)
        var y = rect.midY - total / 2
        for i in 0..<count {
            let trailing = i == count - 1 ? rect.width * 0.62 : rect.width
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.minX + trailing, y: y))
            y += gap
        }
        return path
    }
}

/// 字体分段：内置三种 + 导入的字体，每项用自己的字体显示；导入的多了横向滚动
struct FontPicker: View {
    @Environment(AppModel.self) private var app
    @Namespace private var ns

    private enum Option: Hashable {
        case builtIn(ReaderFontChoice)
        case imported(ImportedFont)
    }

    var body: some View {
        let imported = FontStore.shared.fonts
        let options = ReaderFontChoice.allCases.map(Option.builtIn) + imported.map(Option.imported)
        let segments = ForEach(options, id: \.self) { option in
            segment(option, fill: imported.isEmpty)
        }
        Group {
            if imported.isEmpty {
                HStack(spacing: 0) { segments }
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 0) { segments }
                    }
                    .scrollIndicators(.hidden)
                    .onAppear { proxy.scrollTo(selected, anchor: .center) }
                }
            }
        }
        .frame(height: 46)
        .background(Tok.gFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var selected: Option {
        app.settings.importedFont.map(Option.imported) ?? .builtIn(app.settings.font)
    }

    private func segment(_ option: Option, fill: Bool) -> some View {
        let isOn = selected == option
        return Button {
            guard !isOn else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.snappy) {
                switch option {
                case .builtIn(let font):
                    app.settings.customFont = nil
                    app.settings.font = font
                case .imported(let font):
                    app.settings.customFont = font.id
                }
            }
        } label: {
            label(option)
                .foregroundStyle(Tok.gFg)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, fill ? 0 : 16)
                .frame(minWidth: fill ? nil : 76)
                .frame(maxWidth: fill ? .infinity : nil, maxHeight: .infinity)
                .background {
                    if isOn {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Tok.segBg)
                            .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
                            .matchedGeometryEffect(id: "font", in: ns)
                            .padding(3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(option)
    }

    @ViewBuilder
    private func label(_ option: Option) -> some View {
        switch option {
        case .builtIn(let font): Text(font.name).font(font.preview(16))
        case .imported(let font): Text(font.name).font(.custom(font.id, fixedSize: 16))
        }
    }
}

/// 一排主题卡片，横向滚动，打开时把当前主题滚到可见处。卡片下面写着名字
struct ThemeStrip: View {
    let current: String
    let pick: (ReaderThemeSpec, CGPoint) -> Void
    @Environment(\.colorScheme) private var scheme

    /// 自定义主题排在内置主题前面
    private var themes: [ReaderThemeSpec] {
        let store = ReaderThemeStore.shared
        return store.themes.map { store.spec(for: $0, dark: scheme == .dark) } + ReaderThemeSpec.all
    }

    private var currentName: String {
        themes.first { $0.id == current }?.name ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("主题")
                    .font(.ui(12, .medium))
                    .foregroundStyle(Tok.gFg3)
                Spacer(minLength: 8)
                Text(currentName)
                    .font(.ui(13, .medium))
                    .foregroundStyle(Tok.gFg)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(themes) { theme in
                            ThemeSwatch(theme: theme, selected: theme.id == current) { origin in pick(theme, origin) }
                                .id(theme.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                .onAppear { proxy.scrollTo(current, anchor: .center) }
            }
        }
    }
}

/// 一小页纸：皮肤铺满，自定义主题则把代表图放在纸面上
struct ThemeMark: View {
    let theme: ReaderThemeSpec
    var width: CGFloat = 62
    var height: CGFloat = 80
    var onGlass = false
    var selected = false

    private var artwork: UIImage? {
        guard theme.skin == nil, let id = theme.customID else { return nil }
        return ReaderThemeStore.shared.previewImage(id)
    }

    /// 又高又窄的图是整页背景，铺满卡片；角色图留在右下角
    private var artworkFills: Bool {
        guard let artwork, artwork.size.height > 0 else { return false }
        return artwork.size.width / artwork.size.height < 0.55
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let skin = theme.skin {
                Image(skin.imageName).resizable().scaledToFill()
            } else if let artwork, artworkFills {
                Image(uiImage: artwork).resizable().scaledToFill()
            } else {
                theme.bg
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(theme.fg.opacity(0.8)).frame(width: width * 0.42, height: 3)
                    ForEach(0..<3, id: \.self) { line in
                        Capsule().fill(theme.fg.opacity(0.22)).frame(width: line == 2 ? width * 0.34 : width * 0.62, height: 2)
                    }
                }
                .padding(7)
                .padding(.top, 4)
                if let artwork {
                    Image(uiImage: artwork)
                        .resizable()
                        .scaledToFit()
                        .frame(width: width * 0.5, height: height * 0.42)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(3)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(selected ? Tok.accent : (onGlass ? Tok.gLine : Color.black.opacity(theme.isDark ? 0.28 : 0.08)),
                        lineWidth: selected ? 2 : 1)
        }
    }
}

/// 主题卡片：一页纸样，下面是主题名
struct ThemeSwatch: View {
    let theme: ReaderThemeSpec
    let selected: Bool
    let action: (CGPoint) -> Void

    @State private var frame: CGRect = .zero

    var body: some View {
        Button { action(frame.center) } label: {
            VStack(spacing: 6) {
                ThemeMark(theme: theme, onGlass: true, selected: selected)
                Text(theme.name)
                    .font(.ui(11, selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Tok.gFg : Tok.gFg2)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(width: 84, height: 28, alignment: .top)
            }
            .animation(.bouncy, value: selected)
        }
        .buttonStyle(.press)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .readFrame($frame)
    }
}

/// 翻页方式卡片：选中时循环播放该方式的缩略动画
struct ModeCard: View {
    let style: PageTurnStyle
    let selected: Bool
    let theme: ReaderThemeSpec
    let action: () -> Void

    @State private var pop = false

    var body: some View {
        Button {
            action()
            pop.toggle()
        } label: {
            VStack(spacing: 6) {
                ModePreview(style: style, animating: selected, theme: theme)
                    .frame(width: 46, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(selected ? Tok.accent : Tok.gLine, lineWidth: selected ? 2 : 1)
                    }
                    .keyframeAnimator(initialValue: 1.0, trigger: pop) { view, scale in
                        view.scaleEffect(scale)
                    } keyframes: { _ in
                        CubicKeyframe(0.86, duration: 0.1)
                        SpringKeyframe(1, duration: 0.4, spring: .bouncy)
                    }
                Text(style.label)
                    .font(.ui(11, selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Tok.gFg : Tok.gFg2)
            }
        }
        .buttonStyle(.plain)
    }
}

struct ModePreview: View {
    let style: PageTurnStyle
    let animating: Bool
    let theme: ReaderThemeSpec

    var body: some View {
        TimelineView(.animation(paused: !animating)) { context in
            let t = animating ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2) / 2.2 : 0
            canvas(phase: t)
        }
    }

    /// 一个周期：前 15% 静止，中间翻过去，后 15% 静止
    private func eased(_ t: Double) -> Double {
        let x = min(max((t - 0.15) / 0.7, 0), 1)
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    @ViewBuilder
    private func canvas(phase t: Double) -> some View {
        let p = eased(t)
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                switch style {
                case .curl:
                    page(1)
                    page(0)
                        .rotation3DEffect(.degrees(-100 * p), axis: (0, 1, 0), anchor: .leading, perspective: 0.6)
                        .opacity(p > 0.92 ? 0 : 1)
                case .slide:
                    page(1)
                    page(0)
                        .shadow(color: .black.opacity(0.25 * p), radius: 3, x: 2)
                        .offset(x: -w * p)
                case .scroll:
                    page(0).offset(x: -w * p)
                    page(1).offset(x: w - w * p)
                case .none:
                    if p < 0.5 { page(0) } else { page(1) }
                case .vertical:
                    VStack(spacing: 0) {
                        page(0).frame(height: h)
                        page(1).frame(height: h)
                    }
                    .frame(height: h, alignment: .top)
                    .offset(y: -h * 0.6 * p)
                }
            }
            .frame(width: w, height: h)
        }
    }

    /// 缩略页：几行字
    private func page(_ index: Int) -> some View {
        ZStack(alignment: .topLeading) {
            theme.bg
            VStack(alignment: .leading, spacing: 4.5) {
                ForEach(0..<6, id: \.self) { line in
                    Capsule()
                        .fill(theme.fg.opacity(0.35))
                        .frame(width: line == 5 ? 16 : (index == 0 ? 30 : 28), height: 2)
                }
            }
            .padding(.top, 10)
            .padding(.leading, 8)
        }
    }
}
#endif  // #if canImport(UIKit)
