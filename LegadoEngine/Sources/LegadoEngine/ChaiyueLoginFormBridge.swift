#if os(iOS)
// ⭐⭐⭐⭐⭐ **柴阅的【登录表单】宿主门面转发**（2026-11-27 · 登录页适配柴阅）⭐⭐⭐⭐⭐
//
// ⚠️⚠️⚠️ **为什么要在门面模块里转发**（与 `ChaiyueBrowserOverlayBridge` 同理）⭐⭐⭐：
//   宿主（App target）**不能** `import ChaiyueReader` —— 它 `@_exported import ChaiyueModels`
//   ⇒ 会把柴阅的 `Book`/`BookSource` 带进宿主命名空间 ⇒ 与宿主同名类型 **ambiguous** ⭐⭐⭐
//   ⇒ 而宿主需要柴阅的**登录表单组件** ⇒ ⇒ 在宿主门面模块（`LegadoEngine`）里转发一层 ⭐⭐⭐
//   ⇒ 宿主只 `import LegadoEngine` ⇒ **不撞名**（`LegadoEngine` 没有 `@_exported` 柴阅模型）⭐⭐⭐
import SwiftUI
import ChaiyueEngine
import ChaiyueReader

/// 柴阅的登录表单（宿主可见）
public struct ChaiyueLoginFormBridge: View {
    public typealias Row = ChaiyueEngine.LoginRow

    public let rows: [Row]
    public var title: String
    @Binding public var values: [String: String]
    public var busy: Bool
    public var runningAction: String?
    public var submitTitle: String
    public var onRun: (Row, [String: String]) -> Void
    public var onSubmit: () -> Void

    public init(rows: [Row],
                title: String,
                values: Binding<[String: String]>,
                busy: Bool = false,
                runningAction: String? = nil,
                submitTitle: String = "登录",
                onRun: @escaping (Row, [String: String]) -> Void,
                onSubmit: @escaping () -> Void) {
        self.rows = rows
        self.title = title
        self._values = values
        self.busy = busy
        self.runningAction = runningAction
        self.submitTitle = submitTitle
        self.onRun = onRun
        self.onSubmit = onSubmit
    }

    // ⚠️⭐⭐⭐ **`body` 必须显式标 `@MainActor`**（2026-11-27）⭐⭐⭐
    //   `ChaiyueReader` 是 **Swift 6 + `-default-isolation MainActor`** ⇒ 柴阅的 `ChaiyueLoginForm`
    //   连它的 `init` 都是 **@MainActor 隔离**的 ⭐⭐⭐
    //   ⇒ 本门面模块（`LegadoEngine`）是 **Swift 5、无隔离** ⇒ 从这里调它
    //   ⇒ 必须有 **@MainActor 上下文** ⇒ 显式标注最稳（与 `ChaiyueBrowserOverlayBridge` 同款做法）⭐⭐⭐
    @MainActor
    public var body: some View {
        ChaiyueLoginForm(rows: rows,
                         title: title,
                         values: $values,
                         busy: busy,
                         runningAction: runningAction,
                         submitTitle: submitTitle,
                         onRun: onRun,
                         onSubmit: onSubmit)
    }
}
#endif  // #if os(iOS)
