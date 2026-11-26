import SwiftUI
import ChaiyueModels

// =============================================================================
// ⭐⭐⭐ **柴阅的「登录界面」轻阅实现**（2026-11-26）⭐⭐⭐
//
// ⚠️ 柴阅阅读器里会弹它：`.sheet { SourceLoginSheet(source: source) }` ⇒ **类型必须存在**⭐⭐⭐
//   而柴阅那份是完整的「登录 App 界面」（WolfCenter/WolfAccount/浏览器回跳/验证码…），
//   会拖进一整串 App 层依赖 ⭐⭐⭐
// ⇒ 轻阅的登录界面**另有真实现**：`QiReaderLite/Features/Sources/SourceLoginSheet.swift`
//   （从站方 `loginUi` 求值出按钮那一套）⇒ 这里只做**兜底提示**，不重复实现 ⭐⭐⭐
// ⇒ ⚠️ 已知功能缺口：阅读器内直接登录这条路径走的是轻阅自己的登录面板 ⭐⭐⭐
// =============================================================================

#if os(iOS)

/// 登录界面（轻阅：类型面 + 兜底提示；真正的登录面板在 App 侧）
struct SourceLoginSheet: View {
    let source: BookSource

    var body: some View {
        VStack(spacing: 12) {
            Text("登录「\(source.bookSourceName)」")
                .font(.headline)
            Text("请在「书源 → \(source.bookSourceName) → 登录」里完成登录后返回。")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#endif  // #if os(iOS)
