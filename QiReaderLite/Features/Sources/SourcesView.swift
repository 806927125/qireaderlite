import SwiftUI
import UniformTypeIdentifiers

struct SourcesView: View {
    @EnvironmentObject private var store: SourceStore
    @State private var showFileImporter = false
    @State private var showPaste = false
    @State private var showDiag = false
    @State private var importError: String?
    @State private var netDiagText: String?
    @State private var netDiagBusy = false
    @State private var filter = ""

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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showPaste = true } label: {
                        Label("粘贴 JSON 导入", systemImage: "doc.on.clipboard")
                    }
                    Button { showFileImporter = true } label: {
                        Label("从文件导入", systemImage: "folder")
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
