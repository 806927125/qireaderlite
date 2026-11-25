#if canImport(UIKit)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Design/Compat.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Design/Compat.swift

import SwiftUI
import UIKit

struct ForEachSubview<Content: View, Row: View>: View {
    let content: Content
    let row: (_ index: Int, _ subview: AnyView) -> Row

    init(_ content: Content, @ViewBuilder row: @escaping (_ index: Int, _ subview: AnyView) -> Row) {
        self.content = content
        self.row = row
    }

    var body: some View {
        if #available(iOS 18, *) {
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.offset) { index, subview in
                    row(index, AnyView(subview))
                }
            }
        } else {
            _VariadicView.Tree(VariadicRows(row: row)) { content }
        }
    }
}

private struct VariadicRows<Row: View>: _VariadicView_MultiViewRoot {
    let row: (Int, AnyView) -> Row

    func body(children: _VariadicView.Children) -> some View {
        ForEach(Array(children.enumerated()), id: \.offset) { index, child in
            row(index, AnyView(child))
        }
    }
}
#endif
