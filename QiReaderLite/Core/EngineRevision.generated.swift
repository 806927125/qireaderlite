// ⭐⭐⭐⭐⭐ **引擎 revision（CI 生成 ⇒ 真值）**
//
// ⚠️ **这个文件是自动生成的** ⇒ **不许手改**（手改 = 假证据 ⇒ 会把排查带偏）
//   ⇒ CI 在编译前用「SPM checkout 出来的引擎目录的 git HEAD」覆写它 ⭐⭐⭐
//   ⇒ 本地开发时它是 `unknown` ⇒ **明说不知道**，不是报错 ⭐⭐⭐
//
// ⚠️⚠️ **为什么不能用 `-D` 宏**：Swift 的条件编译标志是「有/无」**不带值**
//   （`-DLEGADO_REVISION=xxx` ⇒ 告警 `flags do not have values in Swift`）⭐⭐⭐
//   ⇒ 而且 `LegadoCore` 是 SPM 依赖 target ⇒ App target 的 `OTHER_SWIFT_FLAGS` 传不进去 ⭐⭐⭐
//   ⇒ 所以：**生成一个文件**才是可靠的通道 ⭐⭐⭐

/// ⭐⭐⭐ **引擎 revision**（CI 注入 ⇒ 真在跑的那一版）
enum EngineRevision {
    /// ⭐ 真实 revision（CI 生成时覆写）
    static let generated: String = "unknown"
}
