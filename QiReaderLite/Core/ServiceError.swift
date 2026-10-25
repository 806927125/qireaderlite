import Foundation

// MARK: - ⭐⭐⭐ 引擎调用的错误类型（**放在独立文件** ⇒ 任何层都能引用）

/// ⭐⭐⭐⭐⭐ **引擎调用失败**（2026-10-25 修：原来它是 `SourceService` 的嵌套类型）
///
/// ⚠️⚠️⚠️ **为什么必须独立成文件**（两个坑叠在一起）：
/// ① `SourceService` 整体标了 `@MainActor` ⇒ 它的**嵌套类型也带主 actor 隔离**
///    ⇒ 而 `LegadoEngineBackend`（**非隔离**的后台层）要抛这个错
///    ⇒ 引用 `SourceService.ServiceError` ⇒ **「cannot find 'SourceService' in scope」**
///    ⇒ **CI 必挂**（2026-10-25 build255 实证）⭐⭐⭐
/// ② 就算提到 `SourceService.swift` 的**顶层** ⇒ 那些**只编 `LegadoEngineBackend.swift`
///    不编 `SourceService.swift`** 的门禁组 ⇒ 照样找不到 ⇒ 还是挂 ⭐⭐⭐
/// ⇒ 所以：**独立文件**才是唯一正解（两边都把它列进编译列表）⭐⭐⭐
///
/// ⇒ 顺带的好处：**错误类型本来就该跨层用** ⇒ 不该藏在某个类里 ⭐⭐⭐
enum ServiceError: LocalizedError {
    case engineFailed(String)
    case badPayload
    var errorDescription: String? {
        switch self {
        case .engineFailed(let m): return m
        case .badPayload: return "引擎返回的数据格式不对"
        }
    }
}
