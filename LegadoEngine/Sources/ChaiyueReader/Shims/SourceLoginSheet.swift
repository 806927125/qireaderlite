#if canImport(UIKit)
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
#endif
