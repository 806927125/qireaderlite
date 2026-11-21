// ⭐⭐⭐⭐⭐ **移植补丁（2026-11-21）**：把 `Digests` 从 `Crypto/Crypto.swift` 拆到这里 ⭐⭐⭐
//
// ⚠️⚠️ **为什么拆**：`Crypto/Crypto.swift` 整体在 `#if canImport(CommonCrypto)` 里
//   ⇒ **Linux 沙盒没有** ⇒ 而 `RuleSession` / `WebBook` 用它算 MD5（缓存键）⭐⭐⭐
//   ⇒ 不拆 ⇒ **Linux 编不到引擎** ⇒ 沙盒门禁全废 ⭐⭐⭐
//
// ⭐⭐⭐ **`import Crypto` 的妙处**（跨平台一个模块名）：
//   · Apple 平台：swift-crypto 3.x = **CryptoKit 的再导出** ⇒ 符号完全一致 ⭐⭐⭐
//   · Linux：swift-crypto = **纯 Swift 实现** ⇒ 同名 API ⭐⭐⭐
//   ⇒ 所以 `import Crypto` 两边都拿到 `Insecure.MD5` / `SHA256` / `HMAC` ⭐⭐⭐
//     ⚠️ 与旧引擎的经验一致：**必须在 Package.swift 声明 swift-crypto 依赖**
//        否则 Apple 上报「Unable to find module dependency: 'Crypto'」⭐⭐⭐
#if canImport(Crypto)
import Crypto
#elseif canImport(CryptoKit)
import CryptoKit
#endif
import Foundation

public enum CryptoError: Error, CustomStringConvertible {
    case invalidKey(String)
    case unsupported(String)
    case failed(String)

    public var description: String {
        switch self {
        case .invalidKey(let m): return "密钥无效：\(m)"
        case .unsupported(let m): return "不支持的算法：\(m)"
        case .failed(let m): return "加解密失败：\(m)"
        }
    }
}

enum Digests {
    static func digest(_ algorithm: String, _ data: Data) -> Data? {
        switch normalize(algorithm) {
        case "MD5": return Data(Insecure.MD5.hash(data: data))
        case "SHA1": return Data(Insecure.SHA1.hash(data: data))
        case "SHA256": return Data(SHA256.hash(data: data))
        case "SHA384": return Data(SHA384.hash(data: data))
        case "SHA512": return Data(SHA512.hash(data: data))
        case "SHA224":
            // ⚠️⚠️ **SHA224 没有跨平台实现**（CryptoKit/swift-crypto 都不提供）⭐⭐⭐
            //   ⇒ 非 Apple 平台返回 nil（站方几乎不用 SHA224 ⇒ 影响可忽略）⭐⭐⭐
            #if canImport(CommonCrypto)
            var out = [UInt8](repeating: 0, count: Int(CC_SHA224_DIGEST_LENGTH))
            data.withUnsafeBytes { _ = CC_SHA224($0.baseAddress, CC_LONG(data.count), &out) }
            return Data(out)
            #else
            return nil
            #endif
        default: return nil
        }
    }

    static func hmac(_ algorithm: String, key: Data, data: Data) -> Data? {
        let k = SymmetricKey(data: key)
        switch normalize(algorithm.replacingOccurrences(of: "hmac", with: "", options: .caseInsensitive)) {
        case "MD5": return Data(HMAC<Insecure.MD5>.authenticationCode(for: data, using: k))
        case "SHA1": return Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: k))
        case "SHA256": return Data(HMAC<SHA256>.authenticationCode(for: data, using: k))
        case "SHA384": return Data(HMAC<SHA384>.authenticationCode(for: data, using: k))
        case "SHA512": return Data(HMAC<SHA512>.authenticationCode(for: data, using: k))
        default: return nil
        }
    }

    private static func normalize(_ name: String) -> String {
        name.uppercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
    }
}
