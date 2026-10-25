#if canImport(FoundationNetworking)
import Foundation
import FoundationNetworking

/// ⚠️ **Linux 的 `URLSessionConfiguration` 少一个属性**（Apple 平台有）：
/// `timeoutIntervalForResource` —— 轻阅的 `HostTools` 用了它。
///
/// ⇒ 只在 Linux 上补上（这个文件**只**在沙盒门禁里编译 ⇒ 不会影响 iOS 真机）。
extension URLSessionConfiguration {
    var timeoutIntervalForResource: TimeInterval {
        get { timeoutIntervalForRequest }
        set { timeoutIntervalForRequest = newValue }
    }
}
#endif
