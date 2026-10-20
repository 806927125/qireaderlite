import SwiftUI
import UniformTypeIdentifiers

struct SourcesView: View {
    @EnvironmentObject private var store: SourceStore
    @State private var showFileImporter = false
    @State private var showPaste = false
    @State private var showURLImport = false
    @State private var showDiag = false
    @State private var importError: String?
    @State private var netDiagText: String?
    @State private var netDiagBusy = false
    @State private var filter = ""
    /// 要登录的书源（点书源行右侧的钥匙图标）
    @State private var loginTarget: BookSource?

    var shown: [BookSource] {
        filter.isEmpty ? store.sources : store.sources.filter {
            $0.name.localizedCaseInsensitiveContains(filter)
                || $0.bookSourceGroup.localizedCaseInsensitiveContains(filter)
        }
    }

    var grouped: [(String, [BookSource])] {
        Dictionary(grouping: shown) { s in
            s.groupPath.first ?? "未分组"
        }.sorted { $0.key < $1.key }
    }

    var body: some View {
        ZStack {
            PageBackdrop()

            VStack(spacing: 0) {
                engineBanner
                listBody
            }
        }
        .navigationTitle("书源 (\(store.enabled.count))")
        .searchable(text: $filter, prompt: "搜书源名 / 分组")
        // 书源登录：点行右侧的钥匙图标
        .sheet(item: $loginTarget) { src in
            SourceLoginSheet(source: src)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showPaste = true } label: {
                        Label("粘贴 JSON 导入", systemImage: "doc.on.clipboard")
                    }
                    Button { showFileImporter = true } label: {
                        Label("从文件导入", systemImage: "folder")
                    }
                    Button { showURLImport = true } label: {
                        Label("从链接导入", systemImage: "link")
                    }
                    Divider()
                    Button { showDiag = true } label: {
                        Label("引擎自检", systemImage: "stethoscope")
                    }
                    Button {
                        netDiagBusy = true
                        Task {
                            netDiagText = await RuleSandbox.shared.probePlainHTTP()
                            netDiagBusy = false
                        }
                    } label: {
                        Label(netDiagBusy ? "检测中…" : "网络自检（明文HTTP）", systemImage: "network")
                    }
                    if !store.sources.isEmpty {
                        Divider()
                        Button(role: .destructive) {
                            store.remove(ids: Set(store.sources.map(\.bookSourceUrl)))
                        } label: { Label("清空全部", systemImage: "trash") }
                    }
                } label: { Image(systemName: "plus.circle.fill") }
            }
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.json, .text, .data],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { urls.forEach(load) }
        }
        .sheet(isPresented: $showPaste) {
            PasteImportView { text in importJSON(text) }
        }
        .sheet(isPresented: $showURLImport) {
            URLImportView { data in importData(data, from: "链接") }
        }
        .alert("引擎自检", isPresented: $showDiag) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(RuleSandbox.shared.diagnose())
        }
        .alert("网络自检", isPresented: Binding(
            get: { netDiagText != nil },
            set: { if !$0 { netDiagText = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(netDiagText ?? "")
        }
        .alert("导入失败", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    /// 引擎没就绪就把原因顶到最上面。
    /// 不然「搜不出东西」和「引擎根本没起来」在用户眼里长得一模一样。
    @ViewBuilder
    private var engineBanner: some View {
        if !RuleSandbox.shared.ready {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(RuleSandbox.shared.statusText)
                    .font(.caption)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(3)
                Spacer(minLength: 0)
                Button("自检") { showDiag = true }
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.12))
        }
    }

    @ViewBuilder
    private var listBody: some View {
        if store.sources.isEmpty {
            EmptyHint(icon: "slider.horizontal.3",
                      title: "还没有书源",
                      subtitle: "点右上角导入 Legado 书源 JSON，或者从别的 App 分享过来")
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        } else if shown.isEmpty {
            EmptyHint(icon: "magnifyingglass", title: "没有匹配的书源")
        } else {
            List {
                ForEach(grouped, id: \.0) { group, list in
                    Section(group) {
                        ForEach(list) { s in
                            row(s)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
                        }
                    }
                    .listSectionSeparator(.hidden)
                }
            }
            // List 默认白底，会把 PageBackdrop 完全盖掉 —— 必须透明才看得到底
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        }
    }

    /// 栖阅截图 2 的列表行：彩色圆角方形图标（首字/emoji）+ 玻璃卡片 + 右侧 chevron
    private func row(_ s: BookSource) -> some View {
        HStack(spacing: 11) {
            SourceBadge(source: s)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(s.bookSourceName.isEmpty ? "(未命名)" : s.bookSourceName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    PillTag(text: "本地", color: Theme.tagOrange)
                }
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.sub.opacity(0.7))
                    Text(s.enabled ? "能用" : "已停用")
                        .font(.system(size: 11))
                        .foregroundStyle(s.enabled ? Theme.sub : Theme.sub.opacity(0.5))
                    Text(hostOf(s))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.sub.opacity(0.75))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            // 有 loginUrl 的源给一个登录入口（登录信息/书籍变量存在本地）
            if let lu = s.loginUrl, !lu.isEmpty {
                Button {
                    loginTarget = s
                } label: {
                    Image(systemName: "key.horizontal.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.sub.opacity(0.55))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .glassCard(cornerRadius: 16)
        .contentShape(Rectangle())
        .onTapGesture { store.setEnabled(!s.enabled, for: s.bookSourceUrl) }
        .swipeActions {
            Button(role: .destructive) {
                store.remove(ids: [s.bookSourceUrl])
            } label: { Label("删除", systemImage: "trash") }
        }
    }

    private func hostOf(_ s: BookSource) -> String {
        URL(string: s.bookSourceUrl)?.host ?? s.bookSourceUrl
    }

    private func load(_ url: URL) {
        let needStop = url.startAccessingSecurityScopedResource()
        defer { if needStop { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let list = try BookSourceParser.parse(data)
            let n = store.importSources(list)
            Toast.show("导入 \(n) 个书源")
        } catch {
            importError = error.localizedDescription
        }
    }

    /// 文件和链接共用这一条，失败提示带上来源好排查
    // ⚠️ 参数名不能叫 `where` —— Swift 保留字，会报
    //    "Expected expression in list of expressions"（字面看不懂：以为在写 where 子句）
    private func importData(_ data: Data, from source: String) {
        do {
            let list = try BookSourceParser.parse(data)
            let n = store.importSources(list)
            Toast.show("从\(source)导入 \(n) 个书源")
        } catch {
            importError = error.localizedDescription
        }
    }

    private func importJSON(_ text: String) {
        do {
            let list = try BookSourceParser.parse(Data(text.utf8))
            let n = store.importSources(list)
            Toast.show("导入 \(n) 个书源")
        } catch {
            importError = error.localizedDescription
        }
    }
}

/// 从链接拉书源 JSON。
/// 为什么加这个：iOS 的文件导入要在 Files App 里翻，沙盒/iSH 下载的文件经常找不到；
/// 粘贴又得手打 1MB。给个 URL 最省事，也跟别的阅读 App 的习惯一致。
struct URLImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var busy = false
    @State private var err: String?
    let onImport: (Data) -> Void

    private var trimmed: String {
        urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func go() async {
        guard let u = URL(string: trimmed), u.scheme != nil else { err = "地址不对"; return }
        busy = true; defer { busy = false }
        var req = URLRequest(url: u)
        req.timeoutInterval = 60
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                err = "HTTP \(http.statusCode)"; return
            }
            // GitHub 的 /blob/ 路径返回的是 HTML 页面，不是 JSON
            if let text = String(data: data, encoding: .utf8),
               text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
                err = "拿到的是网页不是 JSON。GitHub 要用 raw.githubusercontent.com 域名"
                return
            }
            onImport(data)
            dismiss()
        } catch {
            err = error.localizedDescription
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextField("https://…/xxx.json", text: $urlText, axis: .vertical)
                    .font(.system(size: 13, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .padding(11)
                    .background(Theme.sub.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 10))
                Text("贴书源 JSON 的直链，一次导入全部。GitHub 用 raw.githubusercontent.com 那条地址。")
                    .font(.caption).foregroundStyle(Theme.sub)
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("链接导入书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "拉取中…" : "导入") {
                        Task { await go() }
                    }
                    .disabled(busy || trimmed.isEmpty)
                }
            }
            .alert("导入失败", isPresented: Binding(
                get: { err != nil }, set: { if !$0 { err = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(err ?? "") }
        }
    }
}

struct PasteImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    let onImport: (String) -> Void

    var body: some View {
        NavigationStack {
            VStack {
                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(8)
                    .background(Theme.sub.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    .padding()
                Text("把书源 JSON 整段粘进来，支持单个对象、数组，或多个对象拼在一起。")
                    .font(.caption).foregroundStyle(Theme.sub)
                    .padding(.bottom, 8)
            }
            .navigationTitle("粘贴书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        onImport(text)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
