import Foundation
import LegadoEngine

/// ⭐⭐⭐ **柴阅引擎（`LegadoEngine`）接入探针**（2026-11-21 移植柴阅）
///
/// ⚠️⚠️ **这一版探针为什么改了**（移植柴阅的必然结果）：
///   旧探针调的是**旧引擎**的 `AnalyzeRule`（`AnalyzeRule(source:)` + `getString("$.name")`）⭐⭐⭐
///   ⇒ 而柴阅的 `AnalyzeRule` 是 **internal** ⇒ 外部拿不到 ⇒ 旧探针**编不过** ⭐⭐⭐
///   ⇒ 正解：用柴阅的 **public API** 做探针 ⇒ ① `BookSource`（Codable）② 规则模型 ⭐⭐⭐
///
/// ⚠️ **探针的能力边界**（要如实说，别夸大）：
///   探针能证明「**能 import + 能真跑柴阅的模型解码**」⭐⭐⭐
///   ⇒ 但**规则求值**（`AnalyzeRule` / `AnalyzeByJSONPath`）是柴阅的 internal ⇒ 探针验不到 ⭐⭐⭐
///   ⇒ 那部分由**柴阅自带的权威测试**保证（CI 上跑 `swift test`）⭐⭐⭐
enum LegadoEngineProbe {
    static func version() -> String {
        // ⭐⭐⭐ 触发一次**真实调用** ⇒ 证明不只是能 import，还能跑 ⭐⭐⭐
        let json = #"{"bookSourceUrl":"https://probe.invalid","bookSourceName":"探针","ruleBookInfo":{"name":"$.name","intro":"$.intro"}}"#
        guard let data = json.data(using: .utf8),
              let src = try? JSONDecoder().decode(LegadoEngineHost.Source.self, from: data) else {
            return "柴阅引擎（书源解码失败）"
        }
        // 规则字段确实被解出来了 ⇒ 证明柴阅的模型层在跑
        let nameRule = src.ruleBookInfo?.name ?? ""
        let introRule = src.ruleBookInfo?.intro ?? ""
        let ok = nameRule == "$.name" && introRule == "$.intro" && src.bookSourceName == "探针"
        return "柴阅引擎/Chaiyue \(ok ? "✅" : "❌")（书源解码探针 → \(nameRule.isEmpty ? "空" : nameRule)）"
    }
}
