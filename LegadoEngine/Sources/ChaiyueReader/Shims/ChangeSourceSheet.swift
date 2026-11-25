#if canImport(SwiftUI)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Screens/Common/Sheets.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Screens/Common/Sheets.swift

import ChaiyueModels
import ChaiyueReaderServices
import SwiftUI

struct ChangeSourceSheet: View {
    let book: Book
    let onChanged: (Book) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: ChangeSourceModel?
    @State private var switching: String?
    @State private var spin = 0.0

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "换源", count: model.map { "\($0.candidates.count)" }) {
                Button {
                    withAnimation(.out.speed(0.75)) { spin += 360 }
                    model?.refresh()
                } label: {
                    Image(icon: "arrow.clockwise")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Tok.gFg2)
                        .rotationEffect(.degrees(spin))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.press)
            }
            if let model {
                ProgressLine(value: model.total > 0 ? Double(model.completed) / Double(model.total) : 0,
                             done: !model.isSearching)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.candidates) { candidate in
                            row(candidate)
                                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 14)), removal: .opacity))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 22)
                    .animation(.soft, value: model.candidates.map(\.id))
                }
                .overlay {
                    if model.candidates.isEmpty, !model.isSearching {
                        Image(icon: "rectangle.stack.badge.minus")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(Tok.gFg3)
                    }
                }
            } else {
                Spacer()
            }
        }
        .task {
            let model = app.library.changeSourceModel(for: book)
            self.model = model
            model.start()
        }
        .onDisappear { model?.cancel() }
    }

    private func row(_ candidate: SourceCandidate) -> some View {
        let on = candidate.isCurrent
        return Button {
            pick(candidate)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(SourceName.full(candidate.book.originName.isEmpty ? candidate.book.origin : candidate.book.originName))
                        .font(.ui(16, .medium))
                        .foregroundStyle(on ? Tok.gAccent : Tok.gFg)
                        .lineLimit(1)
                    if let latest = candidate.book.latestChapterTitle, !latest.isEmpty {
                        Text(latest.withoutEmoji)
                            .font(.ui(12))
                            .foregroundStyle(Tok.gFg3)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if switching == candidate.id {
                    ProgressView().controlSize(.small)
                } else if candidate.book.respondTime > 0 {
                    Text("\(candidate.book.respondTime) ms")
                        .font(.num(12))
                        .foregroundStyle(Tok.gFg3)
                }
                Image(icon: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Tok.gAccent)
                    .frame(width: 22)
                    .opacity(on ? 1 : 0)
                    .scaleEffect(on ? 1 : 0.2)
                    .animation(.bouncy, value: on)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 66)
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(RowPressStyle(color: Tok.gFill))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .disabled(switching != nil)
    }

    private func pick(_ candidate: SourceCandidate) {
        guard !candidate.isCurrent, switching == nil else { return }
        switching = candidate.id
        Task {
            do {
                let result = try await app.library.changeSource(of: book, to: candidate.book)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onChanged(result.book)
                app.island.show("arrow.triangle.2.circlepath", "已切换到 \(SourceName.display(candidate.book.originName))")
                try? await Task.sleep(for: .milliseconds(320))
                dismiss()
            } catch {
                app.island.show("exclamationmark.triangle", error.localizedDescription, danger: true)
            }
            switching = nil
        }
    }
}
#endif
