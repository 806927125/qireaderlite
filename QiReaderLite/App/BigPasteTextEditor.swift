import SwiftUI
import UIKit

/// ⭐⭐⭐ **不限长度的粘贴框**（2026-10-27 用户要求：「不带上限」）
///
/// ⚠️⚠️ **为什么不能把大文本直接塞进 `UITextView`**（2026-10-24 真机崩溃日志实证）：
///   `TextEditor` = `UITextView` ⇒ **粘贴时立刻做 CoreText 排版**
///   ⇒ 粘进 **158KB 的书源 JSON** ⇒ `TTypesetter::FinishLayout` 排 **10 秒**排不完
///   ⇒ **`scene-update watchdog` 杀进程**（`0x8BADF00D`）⇒ 设备还发烫 ⭐⭐⭐
///
/// ⭐⭐⭐ **本解法 = 「照收全量，但不让它排版」**：
///   · 粘贴的内容**不进气泡**（`override func paste`）⇒ **零排版** ⇒ 永不卡 ⭐
///   · 内容进**缓冲区**（`text` 绑定）⇒ **导入时用全量** ⇒ 大书源照样能导 ⭐
///   · 编辑器里**只显示前 N 字 + 一句提示** ⇒ 用户看得见「粘了多少」⇒ 心里有数 ⭐
///   ⇒ 与 `LimitedTextEditor`（超长**拒收**）的区别：**这里不拒收，全量留着** ⭐⭐⭐
struct BigPasteTextEditor: UIViewRepresentable {
    /// ⭐ 缓冲区里的**全量**文本（导入用它）
    @Binding var text: String
    /// 编辑器里最多显示多少字（超了只显示前缀 ⇒ 不排版）
    var previewLimit: Int = 2_000
    /// 粘贴完成回调（把字符数报给 UI）
    var onPasted: ((Int) -> Void)?

    func makeUIView(context: Context) -> BigPasteTextView {
        let v = BigPasteTextView()
        v.delegate = context.coordinator
        v.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        v.backgroundColor = .clear
        v.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        v.autocorrectionType = .no
        v.autocapitalizationType = .none
        v.smartDashesType = .no
        v.smartQuotesType = .no
        // ⭐⭐⭐ **粘贴不走 UITextView 的默认路径** ⇒ 大文本**不进气泡** ⇒ 不排版
        v.onPaste = { pasted in
            context.coordinator.parent.text = pasted          // ⭐ 全量进缓冲区
            context.coordinator.parent.onPasted?(pasted.count)
            v.text = context.coordinator.preview(pasted)      // ⭐ 只显示前 N 字
            v.isEditable = false                             // ⭐ 大文本不让再编辑（改也是改预览，没意义）
        }
        v.text = context.coordinator.preview(text)
        v.isEditable = text.count <= previewLimit
        return v
    }

    func updateUIView(_ v: BigPasteTextView, context: Context) {
        let want = context.coordinator.preview(text)
        if v.text != want { v.text = want }
        v.isEditable = text.count <= context.coordinator.parent.previewLimit
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: BigPasteTextEditor
        init(_ parent: BigPasteTextEditor) { self.parent = parent }

        /// ⭐ 显示用的预览：超长就只给前缀 + 说明
        func preview(_ s: String) -> String {
            let limit = parent.previewLimit
            guard s.count > limit else { return s }
            return "已粘贴 \(s.count) 字符（只显示前 \(limit) 字，导入用全部内容）\n" + String(s.prefix(limit))
        }

        /// 小文本正常输入 ⇒ 同步回缓冲区
        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }
    }
}

/// ⭐ **会拦截粘贴的 UITextView**（大文本不进气泡 ⇒ 不排版）
final class BigPasteTextView: UITextView {
    /// 粘贴回调（拿到全量文本）
    var onPaste: ((String) -> Void)?

    override func paste(_ sender: Any?) {
        guard let s = UIPasteboard.general.string, !s.isEmpty else { return }
        onPaste?(s)
    }
}
