import SwiftUI
import UIKit

/// ⭐⭐⭐ **带长度上限的文本框**（`TextEditor` 的安全替代）
///
/// ⚠️⚠️ **为什么不能用 `TextEditor`**（2026-10-24 真机崩溃日志实证）：
///   `TextEditor` = `UITextView` ⇒ **粘贴时立刻做 CoreText 排版**
///   ⇒ 粘进 **158KB 的书源 JSON** ⇒ `TTypesetter::FinishLayout` 排 **10 秒**排不完
///   ⇒ **`scene-update watchdog` 杀进程**（`0x8BADF00D` · scene-update · 10 秒）
///   ⇒ 设备还会被排版搞得 **Thermal serious**（发烫）⭐⭐⭐
///
/// ⇒ **修法**：`UITextView` 的 delegate 里**拦掉**超长的输入
///   ⇒ 大文件**根本进不来** ⇒ 不会排版 ⇒ 不会卡死 ⭐
///   ⇒ 并提示「文本太长，请用『从文件导入』」
struct LimitedTextEditor: UIViewRepresentable {
    @Binding var text: String
    /// **最多允许多少字符**（超过就拒收）
    var limit: Int
    /// 超限时回调（用来给用户提示）
    var onOverflow: ((Int) -> Void)?

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.delegate = context.coordinator
        v.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        v.backgroundColor = .clear
        v.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        v.autocorrectionType = .no
        v.autocapitalizationType = .none
        v.smartDashesType = .no
        v.smartQuotesType = .no
        // ⚠️ **不要** `textStorage` 的富文本属性 ⇒ 纯文本 ⇒ 排版最省
        v.text = text
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        if v.text != text { v.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: LimitedTextEditor
        init(_ parent: LimitedTextEditor) { self.parent = parent }

        /// ⭐⭐⭐ **超长就拒收**（这才是真修法：不让它进来 ⇒ 不用排版）
        func textView(_ textView: UITextView,
                      shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool {
            let current = textView.text as NSString
            let projected = current.length - range.length + (text as NSString).length
            if projected > parent.limit {
                // ⭐ 拒收，但**保留用户已经输入的**（别让人白打）
                parent.onOverflow?(projected)
                return false
            }
            parent.text = textView.text
            return true
        }
    }
}
