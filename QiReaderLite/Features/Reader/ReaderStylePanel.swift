import SwiftUI
import UIKit

// ══════════════════════════════════════════════════════════════════
//  ⭐⭐⭐⭐⭐ **柴阅的「外观」面板**（StylePanel）⭐⭐⭐⭐⭐
//
//  柴阅是 **GPL-3.0** ⇒ **只读源码当规格，不抄代码、不拷资源**
//  ⇒ 这里照抄的是**结构 + 参数 + 行为**，实现全部自己写。
//
//  柴阅原版的结构（`App/Sources/Reader/StylePanel.swift`）：
//      VStack(spacing: 18) {
//          brightnessRow                 // sun.min + GlassSlider + sun.max
//          HStack { sizeStepper, SpacingPicker }
//          FontPicker
//          themeRow                      // ThemeStrip
//          modeRow                       // 翻页方式
//      }
//      .presentationDetents([.height(548)])
//      .presentationDragIndicator(.visible)
//
//  ⚠️⚠️⚠️ **与栖阅那版的关键差别**（这轮换掉的核心）：
//    栖阅 = **底部 overlay 磨砂大卡** + 16 个色块 + **8 个功能磁贴**（本轮全删）
//    柴阅 = **sheet**（独立窗口，高 548）+ 细轨滑块 + 步进器 + 分段 + 主题小页纸
// ══════════════════════════════════════════════════════════════════

// MARK: - 行距三档（柴阅的 spacing 是 0/1/2 三档，不是连续值）

/// ⭐⭐⭐ **行距三档** ⇒ 轻阅原来存的是**绝对值**（lineSpacing / paraSpacing）
///   ⇒ 改成**档位**（跟柴阅一样），行距/段距由档位 × 字号算出来。
///   ⇒ 这样改字号时行距会**跟着缩放**（柴阅的行为），不会字号变大行距还是老值。
enum ReaderSpacingLevel: Int, CaseIterable, Identifiable {
    case compact = 0
    case normal  = 1
    case relaxed = 2

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .compact: return "紧凑"
        case .normal:  return "标准"
        case .relaxed: return "宽松"
        }
    }

    /// 行距系数（柴阅默认 0.55）
    var lineFactor: Double {
        switch self {
        case .compact: return 0.42
        case .normal:  return 0.55
        case .relaxed: return 0.72
        }
    }

    /// 段距系数（柴阅默认 0.70）
    var paraFactor: Double {
        switch self {
        case .compact: return 0.48
        case .normal:  return 0.70
        case .relaxed: return 0.95
        }
    }

    func lineSpacing(fontSize: Double) -> Double { (fontSize * lineFactor).rounded() }
    func paraSpacing(fontSize: Double) -> Double { (fontSize * paraFactor).rounded() }

    /// 从旧的绝对值反推档位（一次性迁移用）
    static func nearest(lineSpacing: Double, fontSize: Double) -> ReaderSpacingLevel {
        guard fontSize > 0 else { return .normal }
        let ratio = lineSpacing / fontSize
        var best = ReaderSpacingLevel.normal
        var bestDiff = Double.greatestFiniteMagnitude
        for lv in ReaderSpacingLevel.allCases {
            let d = abs(ratio - lv.lineFactor)
            if d < bestDiff { bestDiff = d; best = lv }
        }
        return best
    }
}

// MARK: - 面板主体

/// 柴阅的「外观」sheet。
struct ReaderStylePanel: View {
    @Binding var fontSize: Double
    @Binding var spacingLevel: Int
    @Binding var fontKey: String
    @Binding var themeKey: String
    @Binding var pageTurnMode: String
    @Binding var followSystem: Bool

    /// 字号变了 ⇒ 宿主要把行距/段距按新字号重算（柴阅的行为）
    var onFontSizeChanged: (Double) -> Void = { _ in }
    /// 间距档变了 ⇒ 宿主要写 lineSpacing / paraSpacing
    var onSpacingChanged: (Int) -> Void = { _ in }
    /// 换配色 ⇒ 宿主要重排（柴阅的 themeRow 也是这样）
    var onThemeChanged: (String) -> Void = { _ in }

    /// ⭐⭐⭐ **屏幕亮度**（柴阅 brightnessRow）—— 轻阅原来没有这项，这次补上
    @AppStorage("reader.brightness") private var brightness: Double = -1

    private var theme: ReaderTheme {
        ReaderTheme.all.first(where: { $0.key == themeKey }) ?? .paper
    }

    private var level: ReaderSpacingLevel {
        ReaderSpacingLevel(rawValue: spacingLevel) ?? .normal
    }

    var body: some View {
        VStack(spacing: 18) {
            brightnessRow
            HStack(spacing: 10) {
                sizeStepper
                spacingPicker
            }
            fontPicker
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
        // ⭐⭐⭐ **强制外观跟阅读主题走** ⇒ 深色阅读时面板也是深色
        //   （否则系统浅色 sheet 上写深色字 = 看不见）⭐⭐⭐
        .preferredColorScheme(theme.isDarkTheme ? .dark : .light)
        .onAppear {
            if brightness < 0 {
                brightness = Double(UIScreen.main.brightness)
            }
        }
    }

    // MARK: ① 亮度

    private var brightnessRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "sun.min")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            ReaderGlassSlider(value: $brightness, range: 0.05...1) { v in
                UIScreen.main.brightness = CGFloat(v)
            }
            Image(systemName: "sun.max")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
        }
        .frame(height: 30)
    }

    // MARK: ② 字号

    private var sizeStepper: some View {
        ReaderFontSizeStepper(size: $fontSize) { v in
            onFontSizeChanged(v)
        }
    }

    // MARK: ② 间距

    private var spacingPicker: some View {
        ReaderSpacingPicker(selection: $spacingLevel) { lv in
            onSpacingChanged(lv)
        }
    }

    // MARK: ③ 字体

    private var fontPicker: some View {
        ReaderFontPicker(selection: $fontKey)
    }

    // MARK: ④ 主题

    private var themeRow: some View {
        ReaderThemeStrip(current: $themeKey) { key in
            onThemeChanged(key)
        }
    }

    // MARK: ⑤ 翻页方式

    private var modeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("翻页方式")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                Text(PageTurnMode.name(for: pageTurnMode))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(PageTurnMode.all) { m in
                        Button { pageTurnMode = m.raw } label: {
                            Text(m.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(pageTurnMode == m.raw ? .white : .primary)
                                .padding(.horizontal, 15)
                                .padding(.vertical, 8)
                                .background(
                                    pageTurnMode == m.raw ? Color.accentColor : Color(.tertiarySystemFill),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 1)
            }
        }
    }
}

// MARK: - 组件 ①　细轨滑块（柴阅 GlassSlider）

/// 柴阅的细轨滑块：胶囊轨 + 圆钮（拖动时放大）+ 竖向拖动不改值（留给下拉面板）。
struct ReaderGlassSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onChange: ((Double) -> Void)?

    @State private var dragging = false
    /// 拖动起点的值；nil = 还没判定方向
    @State private var start: Double?
    @State private var horizontal: Bool?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let knob: CGFloat = dragging ? 26 : 22
            let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.tertiarySystemFill))
                    .frame(height: 6)
                Capsule()
                    .fill(Color.primary.opacity(0.8))
                    .frame(width: max(6, fraction * width), height: 6)
                Circle()
                    .fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                    .offset(x: fraction * max(0, width - knob))
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
                        if !dragging {
                            withAnimation(.snappy) { dragging = true }
                        }
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

// MARK: - 组件 ②　字号步进（柴阅 FontSizeStepper）

/// 柴阅的字号步进：`A`(小) / 数字 / `A`(大)，高 46，圆角 16。
struct ReaderFontSizeStepper: View {
    @Binding var size: Double
    var range: ClosedRange<Double> = 14...30
    var onChange: ((Double) -> Void)?

    var body: some View {
        let value = Int(size.rounded())
        HStack(spacing: 0) {
            Button { step(-1) } label: {
                Text("A")
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ReaderPressStyle())
            .disabled(value <= Int(range.lowerBound))
            Text("\(value)")
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
                .frame(width: 36)
            Button { step(1) } label: {
                Text("A")
                    .font(.system(size: 21, weight: .medium))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ReaderPressStyle())
            .disabled(value >= Int(range.upperBound))
        }
        .foregroundStyle(.primary)
        .frame(height: 46)
        .background(Color(.tertiarySystemFill),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func step(_ delta: Double) {
        let next = min(range.upperBound, max(range.lowerBound, size + delta))
        guard next != size else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.snappy) { size = next }
        onChange?(next)
    }
}

// MARK: - 组件 ③　行距三档（柴阅 SpacingPicker）

/// 柴阅的行距三档：三枚**图标**（画 4 条线，间距不同），选中项有圆角底 + 形变动画。
struct ReaderSpacingPicker: View {
    @Binding var selection: Int
    var onChange: ((Int) -> Void)?

    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ReaderSpacingLevel.allCases) { lv in
                Button {
                    guard selection != lv.rawValue else { return }
                    UISelectionFeedbackGenerator().selectionChanged()
                    withAnimation(.snappy) { selection = lv.rawValue }
                    onChange?(lv.rawValue)
                } label: {
                    ReaderSpacingGlyph(level: lv.rawValue)
                        .stroke(Color.primary, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        .frame(width: 20, height: 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            if selection == lv.rawValue {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(.tertiarySystemFill).opacity(0.9))
                                    .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
                                    .matchedGeometryEffect(id: "reader-spacing", in: ns)
                                    .padding(3)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 46)
        .background(Color(.tertiarySystemFill),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// 行距图标：4 条线，间距随档位变大。
struct ReaderSpacingGlyph: Shape {
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

// MARK: - 组件 ④　字体分段（柴阅 FontPicker）

/// 柴阅的字体分段：每项**用自己的字体**显示；项多了横向滚动。
struct ReaderFontPicker: View {
    @Binding var selection: String

    @Namespace private var ns

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ReaderFont.all) { f in
                        Button {
                            guard selection != f.raw else { return }
                            UISelectionFeedbackGenerator().selectionChanged()
                            withAnimation(.snappy) { selection = f.raw }
                        } label: {
                            Text(f.name)
                                .font(Self.fontFor(f, size: 15))
                                .foregroundStyle(selection == f.raw ? .white : .primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background {
                                    if selection == f.raw {
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(Color.accentColor)
                                            .matchedGeometryEffect(id: "reader-font", in: ns)
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(f.raw)
                    }
                }
                .padding(.horizontal, 1)
            }
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
        }
    }

    /// 每项用它自己的字体渲染（柴阅同款）
    static func fontFor(_ f: ReaderFont, size: CGFloat) -> Font {
        switch f.raw {
        case "song":  return .custom("Songti SC", size: size)
        case "hei":   return .custom("Heiti SC", size: size)
        case "kai":   return .custom("Kaiti SC", size: size)
        case "serif": return .custom("Georgia", size: size)
        default:      return .system(size: size)
        }
    }
}

// MARK: - 组件 ⑤　主题小页纸条（柴阅 ThemeStrip）

/// 柴阅的主题条：横向滚动的**小页纸**卡片，选中态高亮，滚动到当前项（居中）。
struct ReaderThemeStrip: View {
    @Binding var current: String
    var onPick: (String) -> Void = { _ in }

    private var currentName: String {
        ReaderTheme.all.first(where: { $0.key == current })?.name ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("主题")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                Text(currentName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(ReaderTheme.all) { theme in
                            ReaderThemeSwatch(theme: theme, selected: theme.key == current) {
                                onPick(theme.key)
                            }
                            .id(theme.key)
                        }
                    }
                    .padding(.horizontal, 1)
                    .padding(.vertical, 2)
                }
                .onAppear { proxy.scrollTo(current, anchor: .center) }
            }
        }
    }
}

/// 一小页纸：皮肤铺满 + 三条示意行 + 皮肤名（柴阅 ThemeMark 的做法）。
struct ReaderThemeSwatch: View {
    let theme: ReaderTheme
    let selected: Bool
    var onTap: () -> Void = {}

    var body: some View {
        Button { onTap() } label: {
            ZStack(alignment: .topLeading) {
                theme.bg
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(theme.ink.opacity(0.8)).frame(width: 24, height: 3)
                    ForEach(0..<3, id: \.self) { line in
                        Capsule()
                            .fill(theme.ink.opacity(0.22))
                            .frame(width: line == 2 ? 18 : 32, height: 2)
                    }
                }
                .padding(7)
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(theme.skin.name)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(theme.ink.opacity(0.55))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(theme.ink.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 4))
                    }
                    .padding(5)
                }
            }
            .frame(width: 62, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
            )
            .shadow(color: .black.opacity(selected ? 0.18 : 0.06),
                    radius: selected ? 5 : 2, y: selected ? 2 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 小工具

/// 按压态（柴阅 `.buttonStyle(.press)` 的等价物）
struct ReaderPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.45 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
