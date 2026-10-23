import Foundation
import LegadoCore

/// ⭐⭐ **新引擎（legado-engine）接入探针**
///
/// 这轮先把「能不能接进来」这件事在 CI 上验掉：
/// - SPM 远程依赖（`https://github.com/806927125/legado-engine`）能不能解析 + 拉下来
/// - `LegadoCore` 能不能在 iOS 26 target 上编过（SwiftSoup 依赖 + JSC 后端）
/// - 文件夹同步 target 能不能自动收进新写的 Swift 文件
///
/// ⚠️ **老引擎（`Resources/engine/*.js`）一行没动** ⇒ 这一版是纯增量验证。
enum LegadoEngineProbe {
    static func version() -> String {
        // 触发一次真实调用 ⇒ 证明不只是能 import，还能跑
        let json = JSONValue.object(["ok": .bool(true)])
        return "legado-engine \(json.scalarString)"
    }
}
