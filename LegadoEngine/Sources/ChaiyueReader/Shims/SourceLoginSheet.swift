#if os(iOS)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Screens/Sources/SourceSheet.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Screens/Sources/SourceSheet.swift

import ChaiyueModels
import ChaiyueEngine
import ChaiyueReaderServices
import ChaiyueEngine
import SwiftUI
import WebKit

protocol LoginTarget: Sendable {
    /// 书源脚本通知登录界面时用的标识
    var loginKey: String { get }
    var loginRows: [LoginRow] { get }
    var savedLoginInfo: [String: String] { get }
    var loginHeader: String? { get }
    /// 当前的登录界面行（JS 生成的 loginUi 每次重新执行）
    func loadLoginRows() async throws -> [LoginRow]
    func login(formData: [String: String]) async throws
    func runLoginAction(_ action: String, formData: [String: String]) async throws
}

extension WebBook: LoginTarget {
    var loginKey: String { source.bookSourceUrl }
    func loadLoginRows() async throws -> [LoginRow] { try await resolveLoginRows() }
}

extension HttpTTSEngine: LoginTarget {
    var loginKey: String { String(tts.id) }
    func loadLoginRows() async throws -> [LoginRow] { loginRows }
}

struct SourceLoginSheet: View {
    let source: BookSource
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var formless = false

    var body: some View {
        if formless, let page = webURL {
            WebLoginView(source: source, url: page) { dismiss() }
        } else {
            LoginForm(target: app.library.webBook(for: source), title: SourceName.display(source.bookSourceName)) { rows in
                formless = rows.isEmpty
            }
        }
    }

    private var webURL: URL? {
        guard let raw = source.loginUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              !raw.hasPrefix("@js:"), !raw.hasPrefix("<js>") else { return nil }
        guard let url = URL(string: raw, relativeTo: URL(string: source.bookSourceUrl))?.absoluteURL,
              url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }
}

struct LoginForm: View {
    let target: any LoginTarget
    var title = "登录"
    var onLoad: ([LoginRow]) -> Void = { _ in }
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [LoginRow] = []
    @State private var values: [String: String] = [:]
    @State private var busy = false
    @State private var running: Int?
    @State private var loaded = false
    @State private var wolf: WolfSheet?
    @State private var signedIn = false
    @State private var switching = false
    @State private var wolfAccount: WolfAccount?
    @State private var enteringKey = false
    @State private var keyInput = ""

    private struct WolfSheet: Identifiable {
        let source: BookSource
        let base: String
        var id: String { base }
    }

    private struct Section: Identifiable {
        let id: Int
        let buttons: Bool
        var indices: [Int]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .font(.serif(24))
                    .foregroundStyle(Tok.gFg)
                    .lineLimit(1)
                    .padding(.horizontal, 24)
                    .padding(.top, 28)
                    .padding(.bottom, 4)
                if signedIn && !switching {
                    signedInCard
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
                ForEach(sections) { section in
                    if signedIn && !switching && section.id == accountSection?.id {
                        EmptyView()
                    } else if section.buttons {
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
                        if section.id == accountSection?.id, wolfBase != nil {
                            Button("用密钥登录") {
                                keyInput = ""
                                enteringKey = true
                            }
                            .font(.ui(14))
                            .foregroundStyle(Tok.gFg2)
                            .disabled(busy)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.horizontal, 26)
                        }
                    }
                }
            }
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .modifier(BottomBar {
            if rows.contains(where: { $0.type != .button }) {
                let title = signedIn && !switching ? "保存" : (busy && running == nil ? "登录中" : "登录")
                AccentButton(title: title, icon: nil, wide: true) { submit() }
                    .disabled(busy)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
            }
        })
        .environment(\.onGlass, true)
        .qSheet([.medium, .large])
        .alert("用密钥登录", isPresented: $enteringKey) {
            TextField("密钥", text: $keyInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) {}
            Button("登录") { loginWithKey(keyInput) }
        } message: {
            Text("密钥在已登录设备的用户后台里复制")
        }
        .sheet(item: $wolf) { item in
            ScrollView {
                WolfCenterView(source: item.source, base: item.base) { wolf = nil }
            }
            .scrollIndicators(.hidden)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Tok.bg)
        }
        .task {
            guard !loaded else { return }
            await loadRows()
            loaded = true
            refreshSignedIn()
            onLoad(rows)
        }
        .onAppear { app.loginVisible(target.loginKey, true) }
        .onDisappear { app.loginVisible(target.loginKey, false) }
        .onChange(of: app.loginSignal) { _, signal in
            guard loaded, let signal, signal.sourceKey == target.loginKey else { return }
            if let data = signal.loginData {
                for (name, value) in data { values[name] = value }
            } else {
                Task { await loadRows() }
            }
        }
        #if DEBUG
        .task {
            guard let name = DebugLaunch.flag("loginAction") else { return }
            try? await Task.sleep(for: .seconds(2))
            if let index = rows.firstIndex(where: { $0.type == .button && $0.name.contains(name) }) { run(rows[index], index: index) }
        }
        .task {
            guard let key = DebugLaunch.flag("loginKey") else { return }
            try? await Task.sleep(for: .seconds(2))
            loginWithKey(key)
        }
        #endif
    }

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

    private func columns(_ section: Section) -> [GridItem] {
        let basis = section.indices.lazy.compactMap { rows[$0].style?.layoutFlexBasisPercent }.first { $0 > 0 } ?? 0.5
        return Array(repeating: GridItem(.flexible(), spacing: 10), count: min(3, max(1, Int((1 / basis).rounded(.down)))))
    }

    @ViewBuilder
    private func field(_ row: LoginRow) -> some View {
        let label = Self.label(row.name)
        switch row.type {
        case .text, .password:
            let binding = Binding { values[row.name] ?? "" } set: { values[row.name] = $0 }
            HStack(spacing: 14) {
                Text(label.title)
                    .font(.ui(16))
                    .foregroundStyle(Tok.gFg)
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
                .foregroundStyle(Tok.gFg)
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
                    Text(label.title).font(.ui(16)).foregroundStyle(Tok.gFg).lineLimit(1)
                    Spacer(minLength: 8)
                    RollingText(text: value).font(.ui(15)).foregroundStyle(Tok.gFg3)
                    Image(icon: "chevron.up.chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tok.gFg3)
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

    private func action(_ row: LoginRow, index: Int) -> some View {
        let name = row.name.withoutEmoji
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return Button {
            run(row, index: index)
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
                .foregroundStyle(Tok.gFg2)
                Text(name)
                    .font(.ui(15))
                    .foregroundStyle(Tok.gFg)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Tok.gFill, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.press)
        .disabled(busy)
    }

    /// 「自定义服务器(可不填)」拆成标题与占位提示
    private static func label(_ name: String) -> (title: String, hint: String?) {
        let text = name.withoutEmoji
        guard let range = text.range(of: #"[（(][^（()）]+[)）]\s*$"#, options: .regularExpression) else { return (text, nil) }
        let title = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        let hint = text[range].trimmingCharacters(in: CharacterSet(charactersIn: "（()） "))
        return title.isEmpty ? (text, nil) : (title, hint)
    }

    /// 书源按钮原本靠 emoji 区分，这里按关键字换成 SF Symbols；顺序决定优先级（「退出登录」先命中「退出」）
    private static let symbols: [(keys: [String], symbol: String)] = [
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

    private static func symbol(for name: String) -> String {
        symbols.first { entry in entry.keys.contains { name.contains($0) } }?.symbol ?? "ellipsis.circle"
    }

    private func formData() -> [String: String] {
        values.filter { !$0.value.isEmpty }
    }

    /// 取界面行并按已保存的登录信息填值（按钮脚本执行前已保存表单，这里以保存值为准）
    private func loadRows() async {
        do {
            rows = try await target.loadLoginRows()
        } catch {
            rows = target.loginRows
            app.island.show("exclamationmark.triangle", error.localizedDescription, danger: true)
        }
        let saved = target.savedLoginInfo
        for row in rows where row.type != .button {
            values[row.name] = saved[row.name] ?? values[row.name] ?? row.defaultValue ?? row.chars?.first ?? ""
        }
    }

    private func run(_ row: LoginRow, index: Int) {
        guard let action = row.action, !action.isEmpty else { return }
        // 大灰狼的「用户后台」原本打开网页，改用原生个人中心
        if action.trimmingCharacters(in: .whitespacesAndNewlines) == "loginqt()", let webBook = target as? WebBook,
           let base = WolfCenter.base(for: webBook.source, environment: webBook.environment) {
            guard !webBook.environment.cookies.getKey(url: base, key: "qttoken").isEmpty else {
                app.island.show("person.crop.circle", "请先登录")
                return
            }
            wolf = WolfSheet(source: webBook.source, base: base)
            return
        }
        let target = target
        let data = formData()
        let switchFirst = action.contains("login(") && signedIn && accountChanged
        Task {
            busy = true
            running = index
            defer {
                busy = false
                running = nil
            }
            do {
                if switchFirst { try await signOutFirst() }
                try await target.runLoginAction(action, formData: data)
            } catch {
                app.island.show("exclamationmark.triangle", error.localizedDescription, danger: true)
            }
            refreshSignedIn()
        }
    }

    private func submit() {
        let target = target
        let data = formData()
        let wasSignedIn = signedIn && !switching
        let switchFirst = signedIn && accountChanged
        Task {
            busy = true
            defer { busy = false }
            do {
                if switchFirst { try await signOutFirst() }
                try await target.login(formData: data)
                refreshSignedIn()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                if wasSignedIn {
                    app.island.show("checkmark", "已保存")
                } else if signedIn {
                    withAnimation(.snappy) { switching = false }
                    app.island.show("key", "已登录")
                } else {
                    app.island.show("key", data.isEmpty ? "已清除登录信息" : "已登录")
                    dismiss()
                }
            } catch {
                app.island.show("exclamationmark.triangle", error.localizedDescription, danger: true)
            }
        }
    }

    /// 大灰狼的 login() 在邮箱密码为空、登录信息里有「密钥」时走密钥登录：以本机设备码写入 Cookie 并校验
    private func loginWithKey(_ raw: String) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let webBook = target as? WebBook, let base = wolfBase else { return }
        var data = formData()
        if let section = accountSection {
            for index in section.indices { data[rows[index].name] = nil }
        }
        data["密钥"] = key
        Task {
            busy = true
            defer { busy = false }
            do {
                if signedIn { try await signOutFirst() }
                try await webBook.login(formData: data)
            } catch {
                app.island.show("exclamationmark.triangle", error.localizedDescription, danger: true)
            }
            let account = WolfAccount(base: base, environment: webBook.environment)
            await account.load()
            if account.profile == nil {
                webBook.environment.cookies.removeCookie(url: base)
                webBook.environment.sourceLoginDidChange(webBook.source.bookSourceUrl)
            }
            refreshSignedIn()
            if signedIn {
                let saved = target.savedLoginInfo
                for row in rows where row.type != .button { values[row.name] = saved[row.name] ?? values[row.name] }
                withAnimation(.snappy) { switching = false }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                app.island.show("key", "已用密钥登录")
            } else {
                app.island.show("exclamationmark.triangle", "密钥无效或已过期", danger: true)
            }
        }
    }

    // MARK: - 登录状态

    /// 第一组输入项（通常是账号、密码）出现在所有按钮之前时视为账号区
    private var accountSection: Section? {
        sections.first.flatMap { $0.buttons ? nil : $0 }
    }

    private var accountChanged: Bool {
        guard let section = accountSection else { return false }
        let saved = target.savedLoginInfo
        return section.indices.map { rows[$0].name }.contains { name in
            let value = values[name] ?? ""
            return !value.isEmpty && value != (saved[name] ?? "")
        }
    }

    private var logoutAction: String? {
        rows.first { $0.type == .button && ($0.action ?? "").contains("logout") }?.action
    }

    private var wolfBase: String? {
        guard let webBook = target as? WebBook else { return nil }
        return WolfCenter.base(for: webBook.source, environment: webBook.environment)
    }

    /// 大灰狼看服务器 Cookie 里的 qttoken，其他书源看是否保存了登录请求头
    private func refreshSignedIn() {
        if let webBook = target as? WebBook, let base = wolfBase {
            signedIn = !webBook.environment.cookies.getKey(url: base, key: "qttoken").isEmpty
            if signedIn {
                let account = WolfAccount(base: base, environment: webBook.environment)
                wolfAccount = account
                Task { await account.load() }
            } else {
                wolfAccount = nil
            }
        } else {
            signedIn = !(target.loginHeader ?? "").isEmpty
        }
    }

    /// 换账号前先走书源自己的 logout()：书源发现已有凭证时会跳过登录
    private func signOutFirst() async throws {
        guard let logoutAction else { return }
        try await target.runLoginAction(logoutAction, formData: target.savedLoginInfo)
    }

    private func signOut() {
        guard let logoutAction else { return }
        let target = target
        Task {
            busy = true
            defer { busy = false }
            do {
                try await target.runLoginAction(logoutAction, formData: target.savedLoginInfo)
            } catch {
                app.island.show("exclamationmark.triangle", error.localizedDescription, danger: true)
            }
            refreshSignedIn()
            if let section = accountSection {
                let saved = target.savedLoginInfo
                for index in section.indices { values[rows[index].name] = saved[rows[index].name] ?? "" }
            }
            withAnimation(.snappy) { switching = false }
        }
    }

    private var signedInCard: some View {
        let profile = wolfAccount?.profile
        let name = profile?.displayName ?? maskedAccount ?? "已登录"
        let detail = profile.map { "\($0.tier) · \($0.expiry)" } ?? "已登录"
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Text(String(name.withoutEmoji.prefix(1)).uppercased())
                    .font(.serif(22))
                    .foregroundStyle(Tok.accentInk)
                    .frame(width: 48, height: 48)
                    .background(Tok.accentSoft, in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(name.withoutEmoji)
                        .font(.ui(17, .semibold))
                        .foregroundStyle(Tok.gFg)
                        .lineLimit(1)
                    Label(detail, icon: "checkmark.seal.fill")
                        .font(.ui(12))
                        .foregroundStyle(Tok.gFg3)
                        .labelStyle(.titleAndIcon)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                if let base = wolfBase, let webBook = target as? WebBook {
                    cardButton("个人中心", "person.text.rectangle") { wolf = WolfSheet(source: webBook.source, base: base) }
                }
                cardButton("切换账号", "arrow.left.arrow.right") {
                    withAnimation(.snappy) { switching = true }
                }
                if logoutAction != nil {
                    cardButton("退出登录", "rectangle.portrait.and.arrow.right", tint: Tok.accentInk) { signOut() }
                }
            }
        }
        .padding(16)
        .background(Tok.gFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 16)
    }

    private func cardButton(_ title: String, _ symbol: String, tint: Color = Tok.gFg, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, icon: symbol)
                .font(.ui(13, .medium))
                .foregroundStyle(tint)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Tok.gFill2, in: Capsule())
        }
        .buttonStyle(.press)
        .disabled(busy)
    }

    /// 已保存的账号（第一个文本项），邮箱只露前三位
    private var maskedAccount: String? {
        guard let section = accountSection,
              let first = section.indices.first(where: { rows[$0].type == .text }),
              let value = target.savedLoginInfo[rows[first].name], !value.isEmpty else { return nil }
        guard let at = value.firstIndex(of: "@") else {
            return value.count > 6 ? String(value.prefix(3)) + "****" + String(value.suffix(2)) : value
        }
        return String(value[..<at].prefix(3)) + "***" + value[at...]
    }
}

private struct WebLoginView: View {
    let source: BookSource
    let url: URL
    let onClose: () -> Void
    @Environment(AppModel.self) private var app
    @State private var webView = WKWebView(frame: .zero, configuration: {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        return configuration
    }())

    var body: some View {
        NavigationStack {
            LoginWebContainer(webView: webView)
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
            webView.customUserAgent = app.library.environment.webViewUserAgent
            webView.load(URLRequest(url: url))
        }
    }

    private func saveCookies() async {
        let store = app.library.environment.cookies
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
        app.library.environment.sourceLoginDidChange(source.bookSourceUrl)
        app.island.show("key", "已保存登录状态")
    }
}

private struct BottomBar<Bar: View>: ViewModifier {
    @ViewBuilder var bar: Bar

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.safeAreaBar(edge: .bottom) { bar }
        } else {
            content.safeAreaInset(edge: .bottom) { bar }
        }
    }
}

private struct LoginWebContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WebHostView { WebHostView(webView: webView) }
    func updateUIView(_ uiView: WebHostView, context: Context) {}
}
#endif
