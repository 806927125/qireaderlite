import SwiftUI

/// 液态玻璃的「浓度」——全局可调。
///
/// ## 为什么需要它
/// iOS 26 的 `Glass` 只有三档（`.regular` / `.clear` / `.identity`），
/// 档位之间的观感差别很大，而且 `.regular` 偏实、`.clear` 又太透
/// （正文糊在面板上看不清）。用户需要的是**中间可调**。
///
/// ## 语义
/// `glassTint` = 玻璃上那层白的**不透明度**：
///   · 0.0  → 几乎全透（后面的正文/插画直接透出来）
///   · 0.45 → 很实的乳白玻璃（接近 ui.txt 的 rgba(255,255,255,.82)）
///
/// ## 为什么用 Environment 而不是逐个传参
/// 玻璃修饰器有 14 处调用点（Components / BookDetail / Bookshelf / Explore /
/// Reader …），逐个传参必然漏改、也不一致。
/// Environment 一处注入，全站自动跟随。
private struct GlassTintKey: EnvironmentKey {
    static let defaultValue: Double = 0.20
}

extension EnvironmentValues {
    /// 液态玻璃的白色浓度（0 = 最透，0.45 = 最实）
    var glassTint: Double {
        get { self[GlassTintKey.self] }
        set { self[GlassTintKey.self] = newValue }
    }
}

/// 用户可调的玻璃浓度（存 UserDefaults，App 根注入到 environment）
struct GlassTintStore {
    static let key = "reader.glassTint"

    /// 0 ~ 0.45（0 最透）
    static var current: Double {
        get {
            let v = UserDefaults.standard.double(forKey: key)
            // 第一次读（key 不存在）时 double(forKey:) 返回 0 → 当成默认值
            guard UserDefaults.standard.object(forKey: key) != nil else { return 0.20 }
            return min(max(v, 0), 0.45)
        }
        set {
            UserDefaults.standard.set(min(max(newValue, 0), 0.45), forKey: key)
        }
    }

    /// 滑块用：0 ~ 100
    static var percent: Double {
        get { current / 0.45 * 100 }
        set { current = newValue / 100 * 0.45 }
    }
}
