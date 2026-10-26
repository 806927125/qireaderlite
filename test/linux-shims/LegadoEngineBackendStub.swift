import Foundation

// ⭐⭐⭐ **沙盒 stub：适配层（`LegadoEngineBackend`）—— 只给签名，不给实现**
//
// ⚠️⚠️ **为什么需要这个 stub**（2026-10-26 修类型检查门禁时撞到）：
//   `SourceService.swift` 直接调适配层（`LegadoEngineBackend.shared.invoke(...)`）
//   ⇒ 适配层**不在**主门禁的编译清单里（它用 `URLSession`，Linux 的
//     FoundationNetworking 缺 `dataTask(with:completionHandler:)` ⇒ 塞进来主门禁就永远红）
//   ⇒ 不给 stub ⇒ 主门禁报「cannot find 'LegadoEngineBackend' in scope」
//     ⇒ swiftc 中断 ⇒ **后面改过的文件根本没被类型检查过**（假绿）⭐⭐⭐
//
// ⭐⭐⭐ **stub 原则（只给签名 ⇒ 不给实现）**：
//   · 只为「让类型检查跑过去」⇒ 验的是**类型对不对**，不是行为对不对
//   · **绝不能给实现** ⇒ 否则变成「用假实现验真代码」⇒ 失去意义 ⭐⭐⭐
//   · 签名必须与真身**逐字一致**（`invoke` / `dropAllSessions` / `dropSession`）
//     ⇒ 真身改了签名 ⇒ 这里编不过 ⇒ **门禁会提醒**（这才是它该干的事）⭐⭐⭐
//
// ⚠️ 适配层本身有**独立门禁**（真身 + 真 LegadoCore 模块）：
//   `test/linux-typecheck-engine.sh` ⇒ 那里才是验适配层行为的地方 ⭐⭐⭐
final class LegadoEngineBackend {
    static let shared = LegadoEngineBackend()

    /// ⭐ 会话数上限（真身里是 4 ⇒ 签名要对齐；真身由 `linux-typecheck-engine.sh` 验）
    static let maxLiveSessions = 4
    /// ⭐ 当前活着的会话数（面板显示用）
    var liveSessionCount: Int { 0 }

    func invoke(_ op: String, _ payload: [String: Any], source: BookSource) throws -> Any? { nil }
    func dropAllSessions() {}
    func dropSession(for sourceUrl: String) {}
}
