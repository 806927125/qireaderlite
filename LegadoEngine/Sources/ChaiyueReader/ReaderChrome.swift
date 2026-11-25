// ⭐⭐⭐⭐⭐ **平台条件编译补丁**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **为什么需要**：阅读器界面用满 UIKit（`UIScreen` / `UIApplication` / `UIImpactFeedbackGenerator` …）
//   ⇒ **iOS-only** ⇒ Linux 沙盒编不到 SwiftUI/UIKit ⇒ 若不隔离，**整个包的 Linux 编译门禁全废** ⭐⭐⭐
//   ⇒ 用 `#if canImport(UIKit)` 包裹：**Apple 平台功能完全不变**，Linux 上跳过这段界面代码 ⭐⭐⭐
//   ⇒ 与上游的 diff 仅此两行（去掉即可回到柴阅原样）⭐⭐⭐
#if os(iOS)
import ChaiyueReaderKit
import ChaiyueModels
import ChaiyueReaderServices
import SwiftUI

/// 阅读菜单：顶栏、底部面板、章节滑块气泡、朗读条
struct ReaderChrome: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: ReaderModel
    let insets: EdgeInsets
    let close: () -> Void

    @State private var changingSource = false
    @State private var splitting = false
    @State private var loggingIn = false
    @State private var nightFrame: CGRect = .zero
    @State private var toolsShown = false
    @State private var markBounce = 0

    private var speakingHere: Bool {
        app.speech.state != .idle && app.speechBook?.bookUrl == model.book.bookUrl
    }

    var body: some View {
        ZStack {
            // 常驻底层：盖在翻页视图（UIKit）之上的层若首次渲染为空，之后插入的菜单不会显示
            Color.clear
                .allowsHitTesting(false)
            if model.menuVisible {
                VStack(spacing: 0) {
                    topBar
                        .transition(.asymmetric(
                            insertion: .offset(y: -28).combined(with: .scale(scale: 0.94)).combined(with: .opacity),
                            removal: .offset(y: -22).combined(with: .scale(scale: 0.97)).combined(with: .opacity)))
                    Spacer(minLength: 0)
                    bottomPanel
                        .transition(.asymmetric(
                            insertion: .offset(y: 40).combined(with: .scale(scale: 0.94)).combined(with: .opacity),
                            removal: .offset(y: 32).combined(with: .scale(scale: 0.97)).combined(with: .opacity)))
                }
            }
            if let index = model.scrubbing, model.session.chapters.indices.contains(index) {
                VStack {
                    Spacer()
                    ScrubBubble(index: index, title: model.session.chapters[index].title)
                        .padding(.bottom, 186)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            if speakingHere && !model.menuVisible {
                VStack {
                    Spacer()
                    SpeechBar(model: model)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 26)
                        .transition(.offset(y: 30).combined(with: .opacity))
                }
            }
        }
        .animation(.snappy, value: model.scrubbing)
        .animation(.snappy, value: speakingHere)
        .onChange(of: model.menuVisible) { _, on in
            toolsShown = false
            if on { DispatchQueue.main.async { toolsShown = true } }
        }
        .onChange(of: app.speech.spokenRange) { _, range in
            let range = speakingHere ? range : nil
            model.setSpoken(range, chapter: app.speech.chapterIndex)
            guard let range else { return }
            model.follow(spoken: range.location, chapter: app.speech.chapterIndex)
        }
        .sheet(isPresented: $changingSource) {
            ChangeSourceSheet(book: model.book) { newBook in
                if speakingHere {
                    app.speech.stop()
                    app.speechChapterFinished = nil
                }
                model.commitVisiblePosition()
                model.session.close()
                app.openReader(newBook)
            }
            .qSheet([.fraction(0.76), .large])
            .environment(app)
        }
        .sheet(isPresented: $splitting) {
            TxtSplitSheet(book: model.book) { updated in
                if speakingHere {
                    app.speech.stop()
                    app.speechChapterFinished = nil
                }
                model.commitVisiblePosition()
                model.session.close()
                app.openReader(updated)
            }
            .environment(app)
        }
        .sheet(isPresented: $loggingIn, onDismiss: { model.retry(model.pointer.chapter) }) {
            if let source = loginSource {
                SourceLoginSheet(source: source).environment(app)
            }
        }
    }

    private var loginSource: BookSource? {
        guard !model.book.isLocal, let source = app.library.sources.source(for: model.book.origin), source.hasLogin else { return nil }
        return source
    }

    // MARK: - 顶栏

    private var topBar: some View {
        let marks = app.library.shelf.bookmarks(for: model.book)
        let marked = model.isBookmarked(in: marks)
        return HStack(spacing: 2) {
            Button(action: close) {
                Image(icon: "chevron.left")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Tok.gFg)
                    .frame(width: 44, height: 44)
                    // 命中区盖住胶囊左端与上下边距，点偏一点也能返回
                    .padding(.leading, 6)
                    .padding(.vertical, 6)
                    .padding(.trailing, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.press)
            .padding(.leading, -6)
            Text(model.book.name.withoutEmoji)
                .font(.serif(16))
                .foregroundStyle(Tok.gFg)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            if app.customButtonSource(for: model.book) != nil {
                ReaderIconButton(system: "wand.and.stars", size: 19) {
                    customButton(long: false)
                } longPress: {
                    customButton(long: true)
                }
            }
            ReaderIconButton(system: marked ? "bookmark.fill" : "bookmark", size: 19, tint: marked ? Tok.accent : Tok.gFg) {
                toggleBookmark(marks: marks, marked: marked)
            }
            .symbolEffect(.bounce.down, value: markBounce)
            Menu {
                moreMenu
            } label: {
                Image(icon: "ellipsis")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Tok.gFg)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 56)
        .glassSurface(Capsule(), strong: true)
        .padding(.horizontal, 10)
        .padding(.top, max(insets.top - 8, 14))
    }

    @ViewBuilder
    private var moreMenu: some View {
        if !model.book.isLocal {
            Button { changingSource = true } label: { Label("换源", icon: "arrow.triangle.swap") }
        }
        if app.canResplit(model.book) {
            Button { splitting = true } label: { Label("重新分章", icon: "list.number") }
        }
        Button { model.retry(model.pointer.chapter) } label: { Label("刷新本章", icon: "arrow.clockwise") }
        if !model.book.isLocal {
            Button {
                app.settings.paragraphComments.toggle()
            } label: {
                Label(app.settings.paragraphComments ? "关闭段评" : "开启段评",
                      icon: app.settings.paragraphComments ? "text.bubble.fill" : "text.bubble")
            }
        }
        if loginSource != nil {
            Button { loggingIn = true } label: { Label("登录", icon: "key") }
        }
        if !model.session.isOnShelf {
            Button {
                let session = model.session
                app.confirmShelfAdd(session.book) { session.addToShelf(replacing: $0) }
            } label: { Label("加入书架", icon: "plus") }
        }
        Button {
            let book = model.book
            close()
            app.openDetail(book)
        } label: { Label("书籍详情", icon: "info.circle") }
    }

    /// 书源自定义按钮：点按、长按分别发 clickCustomButton、longClickCustomButton，带上当前章节
    private func customButton(long: Bool) {
        let chapters = model.session.chapters
        let chapter = chapters.indices.contains(model.pointer.chapter) ? chapters[model.pointer.chapter] : nil
        app.library.callBack(long ? .longClickCustomButton : .clickCustomButton, book: model.session.book, chapter: chapter)
        UIImpactFeedbackGenerator(style: long ? .medium : .light).impactOccurred()
    }

    private func toggleBookmark(marks: [Bookmark], marked: Bool) {
        guard let range = model.currentRange else { return }
        if marked {
            for mark in marks where mark.chapterIndex == model.pointer.chapter && (range.contains(mark.chapterPos) || range.lowerBound == mark.chapterPos) {
                app.library.shelf.removeBookmark(mark.time)
            }
            app.island.show("bookmark", "已移除书签")
        } else {
            model.session.addBookmark(at: ReadingPosition(chapterIndex: model.pointer.chapter, offset: range.lowerBound))
            markBounce += 1
            app.island.show("bookmark.fill", "已添加书签")
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - 底部面板

    private var bottomPanel: some View {
        let count = model.chapterCount
        let current = model.pointer.chapter
        let dark = model.theme.isDark
        return VStack(spacing: 0) {
            HStack(spacing: 4) {
                ReaderIconButton(system: "backward.fill", size: 17, disabled: current <= 0) {
                    model.jump(chapter: current - 1)
                }
                ChapterScrubber(count: count, value: current) { index in
                    model.scrubbing = index
                } onCommit: { index in
                    if index != current { model.jump(chapter: index) }
                }
                ReaderIconButton(system: "forward.fill", size: 17, disabled: current >= count - 1) {
                    model.jump(chapter: current + 1)
                }
            }
            .frame(height: 52)
            HStack(spacing: 0) {
                tool("list.bullet", "目录", index: 0) { model.panel = .toc }
                tool("headphones", speakingHere ? "朗读中" : "朗读", index: 1) { startSpeech() }
                tool(dark ? "sun.max" : "moon", dark ? "日间" : "夜间", index: 2) {
                    app.appearance.force(dark ? .light : .dark, origin: nightFrame.center)
                }
                .readFrame($nightFrame)
                tool("textformat", "外观", index: 3) { model.panel = .style }
            }
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 10, trailing: 10))
        .glassSurface(UnevenRoundedRectangle(topLeadingRadius: 32, bottomLeadingRadius: 45,
                                             bottomTrailingRadius: 45, topTrailingRadius: 32, style: .continuous),
                      strong: true)
        .padding(.horizontal, 10)
        .padding(.bottom, insets.bottom > 0 ? 24 : 12)
    }

    private func tool(_ icon: String, _ label: String, index: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Group {
                    // textformat 在中文环境会换成「格式」字样，改用文字绘制
                    if icon == "textformat" {
                        Text("Aa").font(.system(size: 19, weight: .regular, design: .serif))
                    } else {
                        Image(icon: icon).font(.system(size: 20, weight: .regular))
                    }
                }
                .frame(height: 24)
                Text(label)
                    .font(.ui(11))
            }
            .foregroundStyle(Tok.gFg)
            .frame(maxWidth: .infinity)
            .frame(height: 66)
            .contentShape(Rectangle())
        }
        .buttonStyle(.press)
        .offset(y: toolsShown ? 0 : 12)
        .opacity(toolsShown ? 1 : 0)
        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.32).delay(0.07 + 0.034 * Double(index)), value: toolsShown)
    }

    // MARK: - 朗读

    private func startSpeech() {
        if speakingHere {
            withAnimation(.easeIn(duration: 0.2)) { model.menuVisible = false }
            return
        }
        let chapter = model.pointer.chapter
        guard let text = model.session.text(of: chapter) else {
            app.island.show("hourglass", "本章还在加载")
            return
        }
        let start = model.currentRange?.lowerBound ?? 0
        ReaderSpeech.speak(app: app, model: model, text: text, from: start)
        withAnimation(.easeIn(duration: 0.2)) { model.menuVisible = false }
    }
}

/// 朗读接力：读完一章自动加载下一章继续
enum ReaderSpeech {
    static func speak(app: AppModel, model: ReaderModel, text: ChapterText, from offset: Int) {
        let settings = app.settings
        app.audio.pause()
        app.speech.speak(text: text.plainContent, from: offset, chapterIndex: text.index, title: text.title,
                         book: model.book.name, rate: settings.speechRate, voiceID: settings.speechVoice,
                         online: app.onlineSpeech)
        app.speechBook = model.book
        app.speechChapterFinished = { [weak app] in
            guard let app else { return }
            continueNext(app: app, model: model)
        }
    }

    private static func continueNext(app: AppModel, model: ReaderModel) {
        let next = app.speech.chapterIndex + 1
        guard model.session.chapters.indices.contains(next) else {
            app.speech.stop()
            return
        }
        Task {
            let state = await model.session.load(next)
            guard case .loaded(let text) = state else {
                app.speech.stop()
                return
            }
            model.jump(chapter: next)
            speak(app: app, model: model, text: text, from: 0)
        }
    }
}

// MARK: - 组件

struct ReaderIconButton: View {
    let system: String
    var size: CGFloat = 20
    var tint: Color = Tok.gFg
    var disabled = false
    let action: () -> Void
    var longPress: (() -> Void)?

    @State private var pressing = false

    var body: some View {
        if let longPress {
            // Button 在长按松手后是否还触发点按随系统版本不同，带长按时改用手势
            icon
                .scaleEffect(pressing ? 0.88 : 1)
                .animation(.snappy(duration: 0.2), value: pressing)
                .onTapGesture(perform: action)
                .onLongPressGesture(minimumDuration: 0.5, perform: longPress) { pressing = $0 }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: "长按", longPress)
                .disabled(disabled)
        } else {
            Button(action: action) { icon }
                .buttonStyle(.press)
                .disabled(disabled)
        }
    }

    private var icon: some View {
        Image(icon: system)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(tint)
            .opacity(disabled ? 0.3 : 1)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
    }
}

/// 章节滑块：拖动时预览章节，松手跳转
struct ChapterScrubber: View {
    let count: Int
    let value: Int
    let onScrub: (Int?) -> Void
    let onCommit: (Int) -> Void

    @State private var drag: CGFloat?
    @State private var last: Int?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let knob: CGFloat = drag == nil ? 18 : 24
            let fraction = drag ?? (count > 1 ? CGFloat(value) / CGFloat(count - 1) : 0)
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
                        let f = min(max(gesture.location.x / max(width, 1), 0), 1)
                        withAnimation(.interactiveSpring) { drag = f }
                        let index = Int((f * CGFloat(max(count - 1, 0))).rounded())
                        if index != last {
                            last = index
                            UISelectionFeedbackGenerator().selectionChanged()
                            onScrub(index)
                        }
                    }
                    .onEnded { _ in
                        if let last { onCommit(last) }
                        withAnimation(.snappy) { drag = nil }
                        last = nil
                        onScrub(nil)
                    }
            )
            .animation(.snappy, value: value)
        }
        .disabled(count < 2)
    }
}

private struct ScrubBubble: View {
    let index: Int
    let title: String

    var body: some View {
        VStack(spacing: 4) {
            Text("第 \(index + 1) 章")
                .font(.ui(12))
                .monospacedDigit()
                .foregroundStyle(Tok.gFg2)
            Text(title.withoutEmoji)
                .font(.serif(18))
                .foregroundStyle(Tok.gFg)
                .lineLimit(1)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .frame(maxWidth: 300)
        .glassSurface(RoundedRectangle(cornerRadius: 22, style: .continuous), strong: true)
        .contentTransition(.numericText())
    }
}

/// 朗读条（原型 `.tts-bar`）
private struct SpeechBar: View {
    @Environment(AppModel.self) private var app
    let model: ReaderModel
    @State private var choosingVoice = false

    var body: some View {
        let speech = app.speech
        HStack(spacing: 2) {
            ZStack {
                if speech.buffering {
                    ProgressView().controlSize(.small).tint(Tok.gFg)
                } else {
                    Equalizer(active: speech.state == .speaking)
                }
            }
            .frame(width: 22, height: 18)
            .padding(.leading, 14)
            Button {
                choosingVoice = true
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(speech.chapterTitle)
                        .font(.ui(13, .medium))
                        .foregroundStyle(Tok.gFg)
                    Text(app.voiceName)
                        .font(.ui(11))
                        .foregroundStyle(Tok.gFg2)
                        .contentTransition(.opacity)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.press)
            small("person.wave.2", 15) { choosingVoice = true }
            small("backward.fill", 15) { speech.skip(-1) }
            Button { speech.toggle() } label: {
                Image(icon: speech.state == .speaking ? "pause.fill" : "play.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Tok.gFg)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.press)
            small("forward.fill", 15) { speech.skip(1) }
            Menu {
                Button("不开启") { speech.setSleep(minutes: nil) }
                ForEach([15, 30, 60, 90], id: \.self) { minutes in
                    Button("\(minutes) 分钟") { speech.setSleep(minutes: minutes) }
                }
            } label: {
                Image(icon: speech.sleepDeadline == nil ? "timer" : "moon.zzz.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(speech.sleepDeadline == nil ? Tok.gFg : Tok.gAccent)
                    .frame(width: 38, height: 38)
                    .contentShape(Circle())
            }
            small("xmark", 14) {
                speech.stop()
                app.speechBook = nil
                app.speechChapterFinished = nil
            }
            .padding(.trailing, 6)
        }
        .frame(height: 66)
        .glassSurface(Capsule(), strong: true)
        .sheet(isPresented: $choosingVoice) {
            ReaderVoiceSheet()
                .qSheet([.fraction(0.62), .large])
                .environment(app)
        }
    }

    private func small(_ icon: String, _ size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(icon: icon)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(Tok.gFg)
                .frame(width: 38, height: 38)
                .contentShape(Circle())
        }
        .buttonStyle(.press)
    }
}

/// 阅读器内的目录 / 书签
struct ReaderTocPanel: View {
    @Environment(AppModel.self) private var app
    let model: ReaderModel

    var body: some View {
        let session = model.session
        TocSheet(chapters: session.chapters, current: model.pointer.chapter, bookUrl: model.book.bookUrl,
                 bookmarks: app.library.shelf.bookmarks(for: model.book), state: session.tocState,
                 onRetry: {
                     Task {
                         await session.refreshToc()
                         model.sessionOpened()
                     }
                 },
                 onPick: { index in
                     model.panel = nil
                     model.menuVisible = false
                     model.jump(chapter: index)
                 },
                 onBookmark: { mark in
                     model.panel = nil
                     model.menuVisible = false
                     model.jump(chapter: mark.chapterIndex, offset: mark.chapterPos)
                 },
                 onDeleteBookmark: { mark in
                     app.library.shelf.removeBookmark(mark.time)
                 })
            .qSheet([.fraction(0.76), .large])
            .environment(app)
    }
}
#endif  // #if canImport(UIKit)
