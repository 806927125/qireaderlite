// ⭐⭐⭐⭐⭐ **引擎 revision（CI 生成 ⇒ 真值）**
//
// ⚠️ **这个文件是自动生成的** ⇒ **不许手改**（手改 = 假证据 ⇒ 会把排查带偏）⭐⭐⭐
//   ⇒ CI 在编译前用「本地引擎包 `LegadoEngine/` 的 git HEAD」覆写它 ⭐⭐⭐
//   ⇒ 本地开发时它是 `unknown` ⇒ **明说不知道**，不是报错 ⭐⭐⭐
//
// ⚠️⚠️ 2026-11-19：引擎整个换成 `LegadoEngine`（Legado 3.0 语义，六阅 iOS 逆向重建）
//   ⇒ 不再是 SPM 远程依赖 ⇒ revision 取**本地包的 git 状态**（或直接标版本号）⭐⭐⭐

/// ⭐⭐⭐ **引擎 revision**（CI 注入 ⇒ 真在跑的那一版）
enum EngineRevision {
    /// ⭐ 真实 revision（CI 生成时覆写）
    static let generated: String = "unknown"
}
