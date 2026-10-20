import SwiftUI
import UIKit

/// 登录状态检测结果（书源列表长按 → 「检测登录状态」）
///
/// 结论只认**服务器**：`LoginStatus.probe` 会绕开站方 JS 直接打一次
/// `/user_api`，服务器返回里有 `id` 才算登录了。
struct LoginStatusSheet: View {
    let source: BookSource
    @Environment(\.dismiss) private var dismiss

    @State private var report: LoginStatusReport?
    @State private var busy = true
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if busy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在问服务器…")
                                .font(.caption)
                                .foregroundStyle(Theme.sub)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    }

                    if let r = report {
                        // 结论条
                        HStack(spacing: 8) {
                            Image(systemName: r.loggedIn ? "checkmark.seal.fill" : "xmark.seal.fill")
                                .foregroundStyle(r.loggedIn ? Color.green : Color.orange)
                            Text(r.verdict)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.6), in: .rect(cornerRadius: 12))

                        // 明细
                        VStack(alignment: .leading, spacing: 6) {
                            Text("检测明细")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                            ForEach(Array(r.lines.enumerated()), id: \.offset) { _, l in
                                Text(l)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(Theme.ink)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.55), in: .rect(cornerRadius: 12))

                        // 站方原文（会员卡片）
                        if !r.stationMessages.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("站方原文")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.ink)
                                Text(r.stationMessages.joined(separator: "\n"))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(Theme.ink)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(12)
                            .background(Color.white.opacity(0.55), in: .rect(cornerRadius: 12))
                        }
                    }
                }
                .padding(14)
            }
            .navigationTitle("登录状态")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let r = report {
                        Button {
                            UIPasteboard.general.string = r.text
                            copied = true
                        } label: {
                            Label(copied ? "已复制" : "复制结果",
                                  systemImage: copied ? "checkmark" : "doc.on.clipboard")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("好") { dismiss() }
                }
            }
            .task {
                report = await LoginStatus.probe(source)
                busy = false
            }
        }
    }
}
