#if canImport(UIKit)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Screens/Rules/TocRulesScreen.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Screens/Rules/TocRulesScreen.swift

import ChaiyueModels
import ChaiyueReaderServices
import SwiftUI

struct TxtSplitSheet: View {
    let book: Book
    var onDone: (Book) -> Void = { _ in }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    @State private var ruleID: Int64?
    @State private var charset: Int
    @State private var source: DecodedText?
    @State private var preview: SplitPreview?
    @State private var working = false

    private static let modes = ["自动识别", "目录规则", "按长度"]
    private static let charsets: [(title: String, value: String)] = [
        ("UTF-8", "UTF-8"), ("GBK", "GB18030"), ("Big5", "Big5"), ("UTF-16LE", "UTF-16LE"), ("UTF-16BE", "UTF-16BE"),
    ]

    init(book: Book, onDone: @escaping (Book) -> Void = { _ in }) {
        self.book = book
        self.onDone = onDone
        let current = (book.charset ?? "").lowercased()
        let index = Self.charsets.firstIndex { $0.value.lowercased() == current } ?? (current.hasPrefix("gb") ? 1 : 0)
        _charset = State(initialValue: index)
    }

    private var rules: [TxtTocRule] { app.library.txtTocRules.rules }

    private var selectedRule: TxtTocRule? {
        let rules = rules
        if let ruleID, let rule = rules.first(where: { $0.id == ruleID }) { return rule }
        let pattern = (preview?.pattern).nilIfEmpty ?? book.tocUrl
        return rules.first { $0.rule == pattern } ?? rules.first(where: \.enable)
    }

    private var tocMode: TxtTocMode? {
        switch mode {
        case 1: selectedRule.map { .pattern($0.rule) }
        case 2: .byLength
        default: .auto
        }
    }

    var body: some View {
        let selected = mode == 1 ? selectedRule : nil
        VStack(spacing: 0) {
            SheetHeader(title: "重新分章") {
                Button(action: apply) {
                    ZStack {
                        Image(icon: "checkmark")
                            .font(.system(size: 16, weight: .bold))
                            .opacity(working ? 0 : 1)
                        if working { ProgressView().tint(Tok.onAccent) }
                    }
                    .foregroundStyle(Tok.onAccent)
                    .frame(width: 36, height: 36)
                    .background(Tok.accent, in: Circle())
                }
                .buttonStyle(.press)
                .disabled(!canApply)
                .opacity(canApply ? 1 : 0.4)
            }
            ScrollView {
                VStack(spacing: 14) {
                    SegmentedChips(items: Self.modes, selection: $mode, height: 36, glass: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    CardGroup(separatorInset: 14) {
                        Menu {
                            Picker("编码", selection: $charset) {
                                ForEach(Self.charsets.indices, id: \.self) { Text(Self.charsets[$0].title).tag($0) }
                            }
                        } label: {
                            SettingRow(title: "编码") {
                                RollingText(text: Self.charsets[charset].title)
                            }
                        }
                    }
                    previewCard
                    if mode == 1 {
                        ruleList(selected: selected?.id)
                            .transition(.opacity.combined(with: .offset(y: 12)))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
                .animation(.snappy, value: mode)
            }
            .scrollIndicators(.hidden)
        }
        .environment(\.onGlass, true)
        .qSheet([.fraction(0.72), .large])
        .task(id: PreviewKey(mode: tocMode, charset: Self.charsets[charset].value)) { await refresh() }
        .onChange(of: mode) { _, value in
            if value == 1, ruleID == nil { ruleID = selectedRule?.id }
        }
        .task {
            #if DEBUG
            if let value = DebugLaunch.flag("splitMode").flatMap(Int.init) {
                try? await Task.sleep(for: .milliseconds(1200))
                mode = value
            }
            if DebugLaunch.flag("splitApply") != nil {
                for _ in 0..<40 where !canApply || preview?.pattern.isEmpty == false && mode == 2 {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                try? await Task.sleep(for: .milliseconds(1500))
                apply()
            }
            #endif
        }
    }

    private var canApply: Bool {
        !working && tocMode != nil && preview?.error == nil && preview != nil
    }

    // MARK: 预览

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let preview, preview.error == nil {
                    Text("\(preview.count)")
                        .font(.num(26, .semibold))
                        .foregroundStyle(Tok.gFg)
                        .contentTransition(.numericText())
                    Text("章").font(.ui(14)).foregroundStyle(Tok.gFg2)
                    Spacer(minLength: 8)
                    Text(ruleName(preview))
                        .font(.ui(13))
                        .foregroundStyle(Tok.gFg3)
                        .lineLimit(1)
                } else if let error = preview?.error {
                    Image(icon: "exclamationmark.triangle")
                        .font(.system(size: 14, weight: .semibold))
                    Text(error).font(.ui(14))
                    Spacer(minLength: 0)
                } else {
                    ProgressView().tint(Tok.gFg3)
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(preview?.error == nil ? Tok.gFg : Tok.gAccent)
            .frame(minHeight: 32)
            if let preview, preview.error == nil {
                Rectangle().fill(Tok.gLine).frame(height: 0.5)
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(preview.titles.enumerated()), id: \.offset) { index, title in
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.num(12))
                                .foregroundStyle(Tok.gFg3)
                                .frame(width: 18, alignment: .trailing)
                            Text(title)
                                .font(.serif(15, bold: false))
                                .foregroundStyle(Tok.gFg2)
                                .lineLimit(1)
                        }
                    }
                    if preview.count > preview.titles.count {
                        Image(icon: "ellipsis")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Tok.gFg3)
                            .padding(.leading, 30)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.gFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(.snappy, value: preview)
    }

    private func ruleName(_ preview: SplitPreview) -> String {
        guard !preview.pattern.isEmpty else { return "按长度" }
        return rules.first { $0.rule == preview.pattern }?.name ?? "自定义"
    }

    private func ruleList(selected: Int64?) -> some View {
        CardGroup(separatorInset: 50) {
            ForEach(rules) { rule in
                Button {
                    guard rule.id != selected else { return }
                    UISelectionFeedbackGenerator().selectionChanged()
                    ruleID = rule.id
                } label: {
                    HStack(spacing: 14) {
                        Image(icon: rule.id == selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20))
                            .foregroundStyle(rule.id == selected ? Tok.gAccent : Tok.gFg3)
                            .contentTransition(.symbolEffect(.replace))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(rule.name.isEmpty ? rule.rule : rule.name)
                                .font(.ui(15))
                                .foregroundStyle(Tok.gFg)
                                .lineLimit(1)
                            if let example = rule.example.nilIfEmpty {
                                Text(example)
                                    .font(.ui(12))
                                    .foregroundStyle(Tok.gFg3)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.row)
            }
        }
    }

    private func refresh() async {
        guard let tocMode else {
            preview = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(160))
        guard !Task.isCancelled else { return }
        let encoding = Self.charsets[charset].value
        let text: String
        if let source, source.charset == encoding {
            text = source.text
        } else {
            let url = app.library.localBooks.fileURL(for: book)
            let decoded = await Task.detached(priority: .userInitiated) { () -> String? in
                guard let url, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
                return TextEncodingDetector.decode(data, charset: encoding)
            }.value
            guard !Task.isCancelled else { return }
            guard let decoded else {
                preview = SplitPreview(error: LocalBookError.fileMissing.localizedDescription)
                return
            }
            source = DecodedText(charset: encoding, text: decoded)
            text = decoded
        }
        let rules = app.library.txtTocRules.enabledRules
        let splitLong = book.readConfig?.splitLongChapter ?? true
        let result = await Task.detached(priority: .userInitiated) { () -> SplitPreview in
            do {
                let result = try TxtChapterSplitter.split(text, mode: tocMode, rules: rules, splitLongChapter: splitLong)
                return SplitPreview(count: result.chapters.count, titles: result.chapters.prefix(6).map(\.title),
                                    pattern: result.pattern)
            } catch {
                return SplitPreview(error: error.localizedDescription)
            }
        }.value
        guard !Task.isCancelled else { return }
        preview = result
    }

    private func apply() {
        guard canApply, let tocMode else { return }
        working = true
        let encoding = Self.charsets[charset].value
        Task {
            do {
                let updated = try await app.library.resplitLocalBook(book, tocMode: tocMode, charset: encoding)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                app.island.show("list.number", "已分为 \(updated.totalChapterNum) 章")
                dismiss()
                onDone(updated)
            } catch {
                working = false
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                app.island.show("exclamationmark.triangle", error.localizedDescription, danger: true)
            }
        }
    }
}

private struct DecodedText {
    var charset: String
    var text: String
}

private struct PreviewKey: Hashable {
    var mode: TxtTocMode?
    var charset: String
}

private struct SplitPreview: Equatable, Sendable {
    var count = 0
    var titles: [String] = []
    var pattern = ""
    var error: String?
}
#endif
