import SwiftUI

/// 液态玻璃的「浓度」——全局可调。
///
/// ## 语义（2026-10-20 改过，之前是错的）
/// `glassTint` = **白纱层的不透明度**（我们自己画的那层，不是系统的 tint）：
///   · 0.00 → 纯玻璃，底下插画/正文直接透出来
///   · 0.85 → 乳白玻璃（≈ 栖阅的 rgba(255,255,255,.82)）
///
/// ## ⚠️ 为什么不能拿 `Glass.tint()` 的 alpha 当不透明度
/// Apple 官方（WWDC25 "Meet Liquid Glass"）对 tint 的定义是
/// 「根据内容亮度生成一系列色调」的**色彩映射**，而且系统会
/// **为了保证可读性自己反向调节 tint 的量**（"The amount of tint and the
/// dynamic range shift to always ensure buttons remain legible"）。
/// → 拿 tint 的 alpha 当滑块 = 系统把设定稀释掉，实测「调了跟没调一样」。
///
/// 官方给 `.clear` 开的药方是：**配一层 dimming layer**。
/// 那层白纱是我们自己画的，alpha 就是我们说了算 → 滑块才真的有用。
///
/// ## 为什么用 Environment 而不是逐个传参
/// 玻璃修饰器有 25 处调用点（Components / BookDetail / Bookshelf / Explore /
/// Reader …），逐个传参必然漏改、也不一致。
/// Environment 一处注入，全站自动跟随。
private struct GlassTintKey: EnvironmentKey {
    static let defaultValue: Double = 0.38
}

extension EnvironmentValues {
    /// 玻璃上的**白纱浓度**（0 = 纯玻璃，0.85 = 乳白玻璃）
    var glassTint: Double {
        get { self[GlassTintKey.self] }
        set { self[GlassTintKey.self] = newValue }
    }
}

/// 用户可调的玻璃浓度（存 UserDefaults，App 根注入到 environment）
struct GlassTintStore {
    static let key = "reader.glassTint"

    /// 白纱浓度上限。0.85 ≈ 栖阅的 `rgba(255,255,255,.82)`（ui.txt 的 --panel）。
    static let maxVeil: Double = 0.85

    /// 滑块 0 ~ 100（UserDefaults 里存的就是这个刻度）
    static var percent: Double {
        get {
            // 第一次读（key 不存在）时 double(forKey:) 返回 0 → 当成默认值
            guard UserDefaults.standard.object(forKey: key) != nil else { return 45 }
            return min(max(UserDefaults.standard.double(forKey: key), 0), 100)
        }
        set {
            UserDefaults.standard.set(min(max(newValue, 0), 100), forKey: key)
        }
    }

    /// 白纱浓度 0 ~ maxVeil（0 最透）
    static var current: Double {
        get { percent / 100 * maxVeil }
        set { percent = newValue / maxVeil * 100 }
    }
}
