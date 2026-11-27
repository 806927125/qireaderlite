#if os(iOS)
// ⭐⭐⭐⭐⭐ **柴阅的【登录页】整包移植**（2026-11-27 · 用户「登录的 UI 也适配柴阅」）⭐⭐⭐⭐⭐
//
// ⚠️⚠️⚠️ **这是什么** ⭐⭐⭐：
//   搬运自柴阅 `App/Sources/Screens/Sources/SourceSheet.swift` 的登录三件套：
//     · `SourceLoginSheet`（整页入口：表单 **or** 网页登录）⭐⭐⭐
//     · `LoginForm`（表单本体：卡片化输入项 + 按钮网格 + 底部主按钮条）⭐⭐⭐
//     · `WebLoginView` + `LoginWebContainer`（网页登录：完成后把 Cookie 存给书源）⭐⭐⭐
//   ⇒ **执行也走柴阅的**：`LoginTarget` 协议 + `extension WebBook: LoginTarget`
//   ⇒ 柴阅的 `WebBook` 已是 public 且有 `init(source:environment:)` ⇒ **宿主能造** ⇒
//     宿主只需给 `source` + `environment` ⇒ **表单取行、跑 action、登录全部是柴阅的引擎** ⭐⭐⭐
//
// ⭐⭐⭐ **与上游的 diff（务必看）**⭐⭐⭐：
//   ① **剥掉「柴阅大灰狼账号体系」**（`WolfSheet`/`WolfAccount`/`signedIn`/`switching`/
//      `enteringKey`/`keyInput`/`loginWithKey`/`accountSection`/`wolfBase`/`signOutFirst`）
//      ⇒ 那套在柴阅 `Screens/Explore/WolfCenter.swift`（721 行）⇒ **轻阅不搬** ⭐⭐⭐
//      ⇒ 所以「已登录态卡片」「用密钥登录」这两块在轻阅里没有 ⇒ 登录态检测仍由宿主侧承担 ⭐⭐⭐
//   ② **不依赖 `AppModel`**（柴阅用 `app.island.show` 弹 toast、`app.loginSignal` 联动）
//      ⇒ 这里改成**回调**：`onToast(icon, message, danger)` ⇒ 宿主接到自己的 toast ⭐⭐⭐
//      ⇒ 「站方脚本要求刷新登录界面」这条联动轻阅本来就没接（登录面板是独立的）⇒ 不做 ⭐⭐⭐
//   ③ **配色**：柴阅原版（`Tok` 玻璃/浅色）—— 用户 2026-11-27 明确选「柴阅原版观感」⭐⭐⭐
//      ⇒ 保留 `Palette` 入口以便将来要「宿主深色」时一行切换 ⭐⭐⭐
//   ④ `BottomBar` 一并搬（iOS 26 用 `safeAreaBar`，更早用 `safeAreaInset`）⭐⭐⭐
import SwiftUI
import WebKit
import ChaiyueEngine
import ChaiyueModels   // ⭐⭐⭐ `BookSource` 在这里（网页登录要书源）⭐⭐⭐

// MARK: - 配色

/// 登录页配色（默认 = 柴阅原版；保留入口以便将来切「宿主深色」时一行改）
public struct ChaiyueLoginPalette {
    public var title: Color
    public var field: Color
    public var secondary: Color
    public var fill: Color
    public var separator: Color
    public var buttonFill: Color
    public var accent: Color
    public var onAccent: Color

    public init(title: Color, field: Color, secondary: Color, fill: Color, separator: Color,
                buttonFill: Color, accent: Color, onAccent: Color) {
        self.title = title
        self.field = field
        self.secondary = secondary
        self.fill = fill
        self.separator = separator
        self.buttonFill = buttonFill
        self.accent = accent
        self.onAccent = onAccent
    }

    /// ⭐⭐⭐ **柴阅原版**（`Tok` 玻璃/浅色）⭐⭐⭐
    public static let chaiyue = ChaiyueLoginPalette(
        title: Tok.gFg,
        field: Tok.gFg,
        secondary: Tok.gFg3,
        fill: Tok.gFill,
        separator: Tok.gLine,
        buttonFill: Tok.gFill,
        accent: Tok.accent,
        onAccent: Tok.onAccent
    )
}

// MARK: - 表单

/// 登录表单（`loginUi`）：按书源给的顺序，连续的输入项合成一张卡片，连续的按钮排成网格（列数取自 flexBasisPercent）；
/// 底部「登录」先保存表单再执行 `login()`，表单为空时清除登录信息
public struct ChaiyueLoginForm: View {
    /// 站方给的行（宿主解析好传进来 ⇒ 保住「先静态后柴阅」的秒开策略）⭐⭐⭐
    public let rows: [LoginRow]
    public var title = "登录"
    /// 表单值（宿主持有 ⇒ 登录信息能落盘）
    @Binding public var values: [String: String]
    /// 有动作在跑（按钮禁用）
    public var busy = false
    /// 正在跑的动作名（按行名匹配 ⇒ 那个按钮转圈）
    public var runningAction: String?
    /// 底部主按钮文案
    public var submitTitle = "登录"
    /// 点某个动作按钮（宿主去跑站方 JS —— 宿主那套带**超时**、**番茄自动抓**、**站方原文收集**）⭐⭐⭐
    public var onRun: (LoginRow, [String: String]) -> Void
    /// 底部「登录」主按钮（宿主去提交登录）
    public var onSubmit: () -> Void

    public init(rows: [LoginRow],
                title: String = "登录",
                values: Binding<[String: String]>,
                busy: Bool = false,
                runningAction: String? = nil,
                submitTitle: String = "登录",
                onRun: @escaping (LoginRow, [String: String]) -> Void,
                onSubmit: @escaping () -> Void) {
        self.rows = rows
        self.title = title
        self._values = values
        self.busy = busy
        self.runningAction = runningAction
        self.submitTitle = submitTitle
        self.onRun = onRun
        self.onSubmit = onSubmit
    }

    private struct Section: Identifiable {
        let id: Int
        let buttons: Bool
        var indices: [Int]
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .font(.serif(24))
                    .foregroundStyle(ChaiyueLoginPalette.chaiyue.title)
                    .lineLimit(1)
                    .padding(.horizontal, 24)
                    .padding(.top, 28)
                    .padding(.bottom, 4)
                ForEach(sections) { section in
                    if section.buttons {
                        LazyVGrid(columns: columns(section), spacing: 10) {
                            ForEach(section.indices, id: \.self) { index in
                                action(rows[index], index: index)
                            }
                        }
                        .padding(.horizontal, 16)
                    } else {
                        CardGroup(separatorInset: 18) {
                            ForEach(section.indices, id: \.self) { index in
                                field(rows[index])
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .modifier(ChaiyueLoginBottomBar {
            if rows.contains(where: { $0.type != .button }) {
                AccentButton(title: busy ? "登录中" : submitTitle, icon: nil, wide: true) { onSubmit() }
                    .disabled(busy)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
            }
        })
    }

    // MARK: - 分组（连续同类合并）

    private var sections: [Section] {
        var result: [Section] = []
        for (index, row) in rows.enumerated() {
            let buttons = row.type == .button
            if let last = result.last, last.buttons == buttons {
                result[result.count - 1].indices.append(index)
            } else {
                result.append(Section(id: result.count, buttons: buttons, indices: [index]))
            }
        }
        return result
    }

    /// 按钮网格的列数（站方给的 `flexBasisPercent` ⇒ 如 0.5 ⇒ 两列）
    private func columns(_ section: Section) -> [GridItem] {
        let basis = section.indices.lazy.compactMap { rows[$0].style?.layoutFlexBasisPercent }.first { $0 > 0 } ?? 0.5
        return Array(repeating: GridItem(.flexible(), spacing: 10), count: min(3, max(1, Int((1 / basis).rounded(.down)))))
    }

    // MARK: - 输入项

    @ViewBuilder
    private func field(_ row: LoginRow) -> some View {
        let label = Self.label(Self.displayName(row))
        switch row.type {
        case .text, .password:
            let binding = Binding { values[row.name] ?? "" } set: { values[row.name] = $0 }
            HStack(spacing: 14) {
                Text(label.title)
                    .font(.ui(16))
                    .foregroundStyle(ChaiyueLoginPalette.chaiyue.field)
                    .lineLimit(1)
                    .layoutPriority(1)
                Group {
                    if row.type == .password {
                        SecureField(label.hint ?? "未填写", text: binding)
                    } else {
                        TextField(label.hint ?? "未填写", text: binding)
                    }
                }
                .font(.ui(16))
                .foregroundStyle(ChaiyueLoginPalette.chaiyue.field)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 52)
        case .toggle, .select:
            let options = row.chars ?? []
            let value = values[row.name] ?? ""
            Menu {
                ForEach(options, id: \.self) { option in
                    Button {
                        values[row.name] = option
                    } label: {
                        if option == value { Label(option, icon: "checkmark") } else { Text(option) }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Text(label.title).font(.ui(16)).foregroundStyle(ChaiyueLoginPalette.chaiyue.field).lineLimit(1)
                    Spacer(minLength: 8)
                    RollingText(text: value).font(.ui(15)).foregroundStyle(ChaiyueLoginPalette.chaiyue.secondary)
                    Image(icon: "chevron.up.chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ChaiyueLoginPalette.chaiyue.secondary)
                }
                .padding(.horizontal, 18)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .menuOrder(.fixed)
        case .button:
            EmptyView()
        }
    }

    // MARK: - 动作按钮

    private func action(_ row: LoginRow, index: Int) -> some View {
        let name = Self.displayName(row).withoutEmoji
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return Button {
            run(row)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    if running == index {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(icon: Self.symbol(for: name)).font(.system(size: 15, weight: .medium))
                    }
                }
                .frame(width: 20)
                .foregroundStyle(ChaiyueLoginPalette.chaiyue.secondary)
                Text(name)
                    .font(.ui(15))
                    .foregroundStyle(ChaiyueLoginPalette.chaiyue.field)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(ChaiyueLoginPalette.chaiyue.buttonFill, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.press)
        .disabled(busy)
    }

    // MARK: - 文案与图标

    /// 显示名：站方可能把人话标题放在 `viewName`（`name` 是技术名）⇒ 优先用 `viewName`
    static func displayName(_ row: LoginRow) -> String {
        let view = row.viewName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return view.isEmpty ? row.name : view
    }

    /// 「自定义服务器(可不填)」拆成标题与占位提示
    static func label(_ name: String) -> (title: String, hint: String?) {
        let text = name.withoutEmoji
        guard let range = text.range(of: #"[（(][^（()）]+[)）]\s*$"#, options: .regularExpression) else { return (text, nil) }
        let title = text[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let hint = text[range].trimmingCharacters(in: CharacterSet(charactersIn: "（()） "))
        return title.isEmpty ? (text, nil) : (title, hint)
    }

    /// 书源按钮原本靠 emoji 区分，这里按关键字换成 SF Symbols；顺序决定优先级（「退出登录」先命中「退出」）
    static let symbols: [(keys: [String], symbol: String)] = [
        (["退出", "注销"], "rectangle.portrait.and.arrow.right"),
        (["注册"], "person.badge.plus"),
        (["扫码"], "qrcode.viewfinder"),
        (["检测", "检查"], "checkmark.seal"),
        (["登录"], "person.crop.circle"),
        (["后台", "用户中心", "个人"], "person.text.rectangle"),
        (["清空", "清除", "删除"], "trash"),
        (["更新", "刷新"], "arrow.triangle.2.circlepath"),
        (["切换", "线路", "源站"], "arrow.left.arrow.right"),
        (["服务器"], "server.rack"),
        (["设置", "配置"], "gearshape"),
        (["打赏", "会员", "福利"], "gift"),
        (["教程", "帮助", "说明"], "book.closed"),
        (["发布页", "网址", "官网"], "link"),
        (["发现"], "safari"),
        (["气泡", "评论"], "bubble.left"),
        (["收藏", "分类"], "square.grid.2x2"),
    ]

    static func symbol(for name: String) -> String {
        symbols.first { entry in entry.keys.contains { name.contains($0) } }?.symbol ?? "ellipsis.circle"
    }

    // MARK: - 取行与执行

    private func formData() -> [String: String] {
        values.filter { !$0.value.isEmpty }
    }

    /// ⭐⭐⭐ **正在跑的动作对应哪一行**（那一行的按钮转圈）⭐⭐⭐
    ///
    /// ⚠️ **按 `action` 匹配，不是按行名**（2026-11-27 修正）⭐⭐⭐：
    ///   柴阅的表单要的是**动作标识**（站方 `loginUi` 里那行的 `action`）
    ///   ⇒ 宿主传进来的就是 action 串 ⇒ 这里反查行号 ⭐⭐⭐
    private var running: Int? {
        guard let runningAction else { return nil }
        return rows.firstIndex { $0.action == runningAction }
    }

    /// ⭐⭐⭐ **点某个动作按钮** ⇒ 交给宿主去跑站方 JS ⭐⭐⭐
    ///   ⇒ 宿主那套带**超时** / **番茄 sessionid 自动抓** / **站方原文收集** ⇒ 能力不丢 ⭐⭐⭐
    ///   ⇒ 这里只负责把**当前表单值**带过去（柴阅原版语义：先存表单再跑 action）⭐⭐⭐
    private func run(_ row: LoginRow) {
        onRun(row, formData())
    }
}

// MARK: - 网页登录

/// 登录网页：完成后把该站点的 Cookie 存给书源（与 Legado 的网页登录一致）
public struct ChaiyueLoginWebView: View {
    public let source: BookSource
    public let environment: SourceEnvironment
    public let url: URL
    public var onToast: (String, String, Bool) = { _, _, _ in }
    public var onClose: () -> Void

    @State private var webView = WKWebView(frame: .zero, configuration: {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        return configuration
    }())

    public init(source: BookSource,
                environment: SourceEnvironment,
                url: URL,
                onToast: @escaping (String, String, Bool) = { _, _, _ in },
                onClose: @escaping () -> Void) {
        self.source = source
        self.environment = environment
        self.url = url
        self.onToast = onToast
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack {
            ChaiyueLoginWebContainer(webView: webView)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(SourceName.display(source.bookSourceName))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消", icon: "xmark") { onClose() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成", icon: "checkmark") {
                            Task {
                                await saveCookies()
                                onClose()
                            }
                        }
                    }
                }
        }
        .task {
            webView.scrollView.delaysContentTouches = false
            webView.customUserAgent = environment.webViewUserAgent
            webView.load(URLRequest(url: url))
        }
    }

    private func saveCookies() async {
        let store = environment.cookies
        let before = store.digest()
        let hosts = [url.host(), webView.url?.host(), URL(string: source.bookSourceUrl)?.host()].compactMap { $0 }
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let matched = cookies.filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return hosts.contains { $0 == domain || $0.hasSuffix("." + domain) }
        }
        let value = matched.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        if !value.isEmpty { store.replaceCookie(url: source.bookSourceUrl, cookie: value) }
        // 番茄这类登录页的 Cookie 在站点域名下，书源脚本按域名来取
        await CookieSync.pullAll(into: store)
        guard store.digest() != before else { return }
        environment.sourceLoginDidChange(source.bookSourceUrl)
        onToast("key", "已保存登录状态", false)
    }
}

struct ChaiyueLoginWebContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WebHostView { WebHostView(webView: webView) }
    func updateUIView(_ uiView: WebHostView, context: Context) {}
}

// MARK: - 底部条

/// 底部条（iOS 26 用 `safeAreaBar`，更早用 `safeAreaInset`）—— 照搬柴阅
struct ChaiyueLoginBottomBar<Bar: View>: ViewModifier {
    @ViewBuilder var bar: Bar

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.safeAreaBar(edge: .bottom) { bar }
        } else {
            content.safeAreaInset(edge: .bottom) { bar }
        }
    }
}
#endif  // #if os(iOS)
