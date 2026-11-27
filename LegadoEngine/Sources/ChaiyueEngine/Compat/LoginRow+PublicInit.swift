// ⭐⭐⭐⭐⭐ **柴阅 `LoginRow` 的 public 构造器**（2026-11-26 · 登录页适配柴阅）⭐⭐⭐⭐⭐
//
// ⚠️⚠️ **为什么需要** ⭐⭐⭐：
//   柴阅的 `LoginRow`（`ChaiyueEngine/Engine/WebBook.swift`）成员都是 public var
//   ⇒ 但 **Swift 合成出来的 memberwise init 是 internal** ⇒ **宿主 App 构造不了行** ⭐⭐⭐
//   ⇒ 而宿主要保留自己的「**先静态后柴阅**」取行策略（柴阅的 `resolveLoginRows` 对静态源
//     可能返回**预设行**而不是站方真正的行 ⇒ 会把静态源的按钮顶掉）⭐⭐⭐
//   ⇒ 所以：宿主自己解析出静态行 ⇒ 构造成 `LoginRow` ⇒ 交给柴阅的表单组件渲染 ⭐⭐⭐
//
// ⚠️ **不改柴阅源码**（新增扩展即可）⭐⭐⭐
import ChaiyueEngine

public extension LoginRow {
    /// 宿主侧构造一行（`style` 默认 nil ⇒ 按钮网格退回柴阅默认的两列）
    init(name: String,
         type: Kind,
         action: String? = nil,
         chars: [String]? = nil,
         defaultValue: String? = nil,
         style: ExploreKind.Style? = nil,
         viewName: String? = nil) {
        self.name = name
        self.type = type
        self.action = action
        self.chars = chars
        self.defaultValue = defaultValue
        self.style = style
        self.viewName = viewName
    }
}
