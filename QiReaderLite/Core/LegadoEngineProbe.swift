import Foundation
import LegadoEngine

/// ⭐⭐⭐ **新引擎（`LegadoEngine`）接入探针**（2026-11-19）
///
/// 这一版把引擎整个换掉了：
/// - 老的两条（WebView JS 引擎 / 自研 Swift 引擎）**已物理删除**
/// - 新引擎 = `LegadoEngine`（Legado 3.0 语义，从「六阅 LegadoR iOS」二进制逆向重建）
/// - 探针要证明的不只是「能 import」，而是**能真跑一次规则解析** ⭐⭐⭐
enum LegadoEngineProbe {
    static func version() -> String {
        // 触发一次真实调用 ⇒ 证明不只是能 import，还能跑
        let json = #"{"name":"天渊","author":"沐潇三生"}"#
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "LegadoEngine（解析失败）"
        }
        let rule = AnalyzeRule(source: nil)
        let out = (try? rule.getString("$.name")) ?? ""
        let ok = out == "天渊"
        return "LegadoEngine \(ok ? "✅" : "❌")（JSONPath 探针 → \(out.isEmpty ? "空" : out)）"
    }
}
