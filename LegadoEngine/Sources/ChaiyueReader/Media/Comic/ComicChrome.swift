#if os(iOS)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Media/Comic/ComicChrome.swift 搬运**（2026-11-26 · 柴阅漫画阅读器 vendor）⭐⭐⭐⭐⭐
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Media/Comic/ComicChrome.swift
//
// ⚠️⚠️ **与上游的 diff**（只有这些，其余一字未改）⭐⭐⭐：
//   ① `import ReaderModels` → `import ChaiyueModels`、`import ReaderServices` → `import ChaiyueReaderServices`
//      （模块改名，与本仓库其它 vendor 文件一致）⭐⭐⭐
//   ② 整文件包进 `#if os(iOS)`（漫画阅读器用满 UIKit ⇒ macOS/Linux 编不到 ⇒ 与本仓库其它 iOS 界面件一致）⭐⭐⭐
//   ③ `MediaKindStyle.swift` 里 `BookMediaKind` 的三个成员升 public（宿主要用「漫画」角标与「开始看漫画」文案）⭐⭐⭐
import SwiftUI

/// 漫画菜单：顶部书名与章节、底部页码滑杆与工具；菜单收起时显示页码小标
struct ComicChrome: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: ComicModel
    let insets: EdgeInsets
    let close: () -> Void
    @Binding var showingToc: Bool
    let setBrightness: (Double) -> Void

    @State private var scrubbing: Int?
    @State private var adjustingBrightness = false
    @State private var brightness = Double(UIScreen.main.brightness)

    private var count: Int { model.pageCount(model.current.chapter) ?? 0 }
    private var page: Int { scrubbing ?? model.current.page }

    var body: some View {
        ZStack {
            // 常驻底层：盖在 UIKit 阅读视图之上的层若首次渲染为空，之后插入的菜单不会显示
            Color.clear
                .allowsHitTesting(false)
            if model.isReady && !model.menuVisible && count > 0 {
                indicator
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            if model.menuVisible {
                VStack(spacing: 0) {
                    topBar
                        .transition(.asymmetric(
                            insertion: .offset(y: -28).combined(with: .scale(scale: 0.94)).combined(with: .opacity),
                            removal: .offset(y: -22).combined(with: .scale(scale: 0.97)).combined(with: .opacity)))
                    Spacer(minLength: 0)
                    if model.isReady {
                        bottomPanel
                            .transition(.asymmetric(
                                insertion: .offset(y: 40).combined(with: .scale(scale: 0.94)).combined(with: .opacity),
                                removal: .offset(y: 32).combined(with: .scale(scale: 0.97)).combined(with: .opacity)))
                    }
                }
            }
        }
        .onChange(of: model.menuVisible) { _, on in
            if !on { adjustingBrightness = false }
        }
    }

    // MARK: - 页码

    @ViewBuilder
    private var indicator: some View {
        let text = Text("\(model.current.page + 1) / \(count)")
        if model.mode == .strip {
            text
                .font(.ui(10.5, .semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .environment(\.colorScheme, .dark)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 16)
                .padding(.bottom, 18)
        } else {
            text
                .font(.ui(12, .semibold))
                .tracking(1)
                .monospacedDigit()
                .foregroundStyle(Color(light: UIColor(hex: 0x14142B, alpha: 0.45), dark: UIColor(white: 1, alpha: 0.55)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 40)
        }
    }

    // MARK: - 顶栏

    private var subtitle: String {
        let title = model.title(model.current.chapter)
        if title.hasPrefix("第") || title.isEmpty { return title }
        return "第 \(model.current.chapter + 1) 话 · \(title)"
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button(action: close) {
                Image(icon: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.press)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.book.name.withoutEmoji)
                    .font(.serif(14.5))
                    .tracking(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.ui(11))
                        .opacity(0.55)
                        .contentTransition(.opacity)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                if !model.session.isOnShelf {
                    Button {
                        let session = model.session
                        app.confirmShelfAdd(session.book) { session.addToShelf(replacing: $0) }
                    } label: { Label("加入书架", icon: "plus") }
                }
                Button { model.refreshCurrent() } label: { Label("刷新本章", icon: "arrow.clockwise") }
            } label: {
                Image(icon: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
        }
        .foregroundStyle(Tok.gFg)
        .padding(.horizontal, 8)
        .frame(height: 52)
        .glassSurface(Capsule(), strong: true)
        .padding(.horizontal, 14)
        .padding(.top, max(insets.top - 9, 14))
    }

    // MARK: - 底部面板

    private var bottomPanel: some View {
        let chapter = model.current.chapter
        let previous = model.neighbor(chapter, -1)
        let next = model.neighbor(chapter, 1)
        return VStack(spacing: 0) {
            ZStack {
                if adjustingBrightness {
                    HStack(spacing: 12) {
                        Image(icon: "sun.min").font(.system(size: 15, weight: .medium))
                        ComicSlider(value: $brightness)
                            .onChange(of: brightness) { _, value in setBrightness(value) }
                        Image(icon: "sun.max").font(.system(size: 17, weight: .medium))
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else {
                    VStack(spacing: 8) {
                        HStack(spacing: 12) {
                            chapterButton("上一话", target: previous)
                            ChapterScrubber(count: count, value: model.current.page) { index in
                                scrubbing = index
                                if let index { model.seek(index) }
                            } onCommit: { index in
                                model.seek(index)
                            }
                            .frame(height: 24)
                            chapterButton("下一话", target: next)
                        }
                        Text("第 \(page + 1) 页，共 \(count) 页")
                            .font(.ui(11, .medium))
                            .monospacedDigit()
                            .opacity(0.5)
                            .contentTransition(.numericText())
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .frame(height: 46)
            HStack(alignment: .center, spacing: 0) {
                tool("list.bullet", "目录", on: false) { showingToc = true }
                ComicModeSwitch(mode: $model.mode)
                    .frame(maxWidth: .infinity)
                tool("sun.max", "亮度", on: adjustingBrightness) {
                    brightness = Double(UIScreen.main.brightness)
                    withAnimation(.snappy) { adjustingBrightness.toggle() }
                }
            }
            .padding(.top, 16)
        }
        .foregroundStyle(Tok.gFg)
        .padding(EdgeInsets(top: 16, leading: 16, bottom: 14, trailing: 16))
        .glassSurface(RoundedRectangle(cornerRadius: 30, style: .continuous), strong: true)
        .padding(.horizontal, 14)
        .padding(.bottom, insets.bottom > 0 ? 26 : 14)
    }

    private func chapterButton(_ title: String, target: Int?) -> some View {
        Button {
            guard let target else { return }
            model.jump(chapter: target)
        } label: {
            Text(title)
                .font(.ui(12.5, .semibold))
                .opacity(target == nil ? 0.3 : 1)
                .frame(height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.press)
        .disabled(target == nil)
    }

    private func tool(_ icon: String, _ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(icon: icon)
                    .font(.system(size: 18, weight: .regular))
                    .frame(height: 20)
                Text(label).font(.ui(11))
            }
            .opacity(on ? 1 : 0.75)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.press)
    }
}

/// 条漫 | 翻页（原型 `.mh .seg`）
private struct ComicModeSwitch: View {
    @Binding var mode: ComicMode
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            item("条漫", .strip)
            item("翻页", .pager)
        }
        .padding(3)
        .background(Tok.gFill, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func item(_ title: String, _ value: ComicMode) -> some View {
        let on = mode == value
        return Button {
            guard !on else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.snappy) { mode = value }
        } label: {
            Text(title)
                .font(.ui(11.5, .semibold))
                .opacity(on ? 1 : 0.5)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background {
                    if on {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Tok.segBg)
                            .shadow(color: Color(hex: 0x14142B).opacity(0.15), radius: 2, y: 1)
                            .matchedGeometryEffect(id: "pill", in: ns)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 连续值滑杆，外观同章节滑块
private struct ComicSlider: View {
    @Binding var value: Double
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let knob: CGFloat = dragging ? 24 : 18
            let fraction = CGFloat(min(max(value, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Tok.gFill2).frame(height: 4)
                Capsule().fill(Tok.gFg.opacity(0.85)).frame(width: max(4, fraction * width), height: 4)
                Circle()
                    .fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
                    .offset(x: fraction * (width - knob))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !dragging { withAnimation(.snappy) { dragging = true } }
                        value = Double(min(max(gesture.location.x / max(width, 1), 0), 1))
                    }
                    .onEnded { _ in withAnimation(.snappy) { dragging = false } }
            )
        }
        .frame(height: 24)
    }
}

#endif  // #if os(iOS)
