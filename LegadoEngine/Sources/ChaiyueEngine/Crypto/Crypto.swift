#if canImport(CommonCrypto) && canImport(CryptoKit)
import CommonCrypto
import CryptoKit
import Foundation


/// Java 风格的 transformation，例如 `AES/CBC/PKCS5Padding`
struct CipherSpec {
    var algorithm: String
    var mode: String
    var padding: String

    init(_ transformation: String) {
        let parts = transformation.split(separator: "/").map { String($0).trimmedWhitespace }
        algorithm = (parts.first ?? "AES").uppercased()
        mode = parts.count > 1 ? parts[1].uppercased() : "ECB"
        padding = parts.count > 2 ? parts[2].uppercased() : "PKCS5PADDING"
        if algorithm == "TRIPLEDES" || algorithm == "3DES" { algorithm = "DESEDE" }
    }

    var blockSize: Int { algorithm == "AES" ? kCCBlockSizeAES128 : kCCBlockSizeDES }
}

enum SymmetricCipher {
    static func crypt(_ transformation: String, encrypt: Bool, key: Data, iv: Data?, data: Data,
                      tagLength: Int = 16, aad: Data = Data()) throws -> Data {
        let spec = CipherSpec(transformation)
        if spec.mode == "GCM" {
            return try gcm(encrypt: encrypt, key: key, iv: iv ?? Data(), data: data, tagLength: tagLength, aad: aad)
        }
        let (alg, keyData) = try algorithm(spec, key: key)
        let mode: CCMode
        switch spec.mode {
        case "ECB": mode = CCMode(kCCModeECB)
        case "CBC": mode = CCMode(kCCModeCBC)
        case "CFB": mode = CCMode(kCCModeCFB)
        case "CFB8": mode = CCMode(kCCModeCFB8)
        case "OFB": mode = CCMode(kCCModeOFB)
        case "CTR": mode = CCMode(kCCModeCTR)
        default: throw CryptoError.unsupported(transformation)
        }
        let isStream = ["CFB", "CFB8", "OFB", "CTR"].contains(spec.mode)
        // CommonCrypto 只按分组长度读取 IV，多出的字节会被静默忽略。
        // Hutool 5.8.22 + BouncyCastle 1.86（Legado 当前依赖）会直接拒绝，书源才能走进 catch。
        if ["CBC", "CFB", "CFB8", "OFB"].contains(spec.mode), let provided = iv, !provided.isEmpty,
           provided.count != spec.blockSize {
            throw CryptoError.invalidKey("\(spec.mode) 的 IV 长度为 \(provided.count)，需要 \(spec.blockSize) 字节")
        }
        var input = data
        var padding = CCPadding(ccNoPadding)
        switch spec.padding {
        case "PKCS5PADDING", "PKCS7PADDING":
            if !isStream { padding = CCPadding(ccPKCS7Padding) }
        case "ZEROPADDING":
            if encrypt, !isStream, input.count % spec.blockSize != 0 {
                input.append(Data(count: spec.blockSize - input.count % spec.blockSize))
            }
        default:
            break
        }
        let ivData: Data? = spec.mode == "ECB" ? nil : (iv.flatMap { $0.isEmpty ? nil : $0 } ?? Data(count: spec.blockSize))
        var cryptor: CCCryptorRef?
        let options = spec.mode == "CTR" ? CCModeOptions(kCCModeOptionCTR_BE) : 0
        let status = keyData.withUnsafeBytes { keyPtr in
            withOptionalBytes(ivData) { ivPtr in
                CCCryptorCreateWithMode(
                    CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), mode, alg, padding,
                    ivPtr, keyPtr.baseAddress, keyData.count, nil, 0, 0, options, &cryptor
                )
            }
        }
        guard status == kCCSuccess, let cryptor else { throw CryptoError.failed("创建失败(\(status))") }
        defer { CCCryptorRelease(cryptor) }
        let outLength = CCCryptorGetOutputLength(cryptor, input.count, true)
        var out = Data(count: outLength)
        var moved = 0
        var finalMoved = 0
        let s1 = out.withUnsafeMutableBytes { outPtr in
            input.withUnsafeBytes { inPtr in
                CCCryptorUpdate(cryptor, inPtr.baseAddress, input.count, outPtr.baseAddress, outLength, &moved)
            }
        }
        guard s1 == kCCSuccess else { throw CryptoError.failed("处理失败(\(s1))") }
        let s2 = out.withUnsafeMutableBytes { outPtr in
            CCCryptorFinal(cryptor, outPtr.baseAddress! + moved, outLength - moved, &finalMoved)
        }
        guard s2 == kCCSuccess else { throw CryptoError.failed("填充校验失败(\(s2))") }
        out.count = moved + finalMoved
        if !encrypt, spec.padding == "ZEROPADDING" {
            while let last = out.last, last == 0 { out.removeLast() }
        }
        return out
    }

    private static func algorithm(_ spec: CipherSpec, key: Data) throws -> (CCAlgorithm, Data) {
        switch spec.algorithm {
        case "AES":
            // 与 Hutool 一致：只接受 16/24/32 字节，不截断、不补零
            guard [16, 24, 32].contains(key.count) else { throw CryptoError.invalidKey("AES 密钥长度为 \(key.count)") }
            return (CCAlgorithm(kCCAlgorithmAES), key)
        case "DES":
            guard key.count >= 8 else { throw CryptoError.invalidKey("DES 密钥长度为 \(key.count)") }
            return (CCAlgorithm(kCCAlgorithmDES), key.prefix(8))
        case "DESEDE":
            if key.count == 16 { return (CCAlgorithm(kCCAlgorithm3DES), key + key.prefix(8)) }
            guard key.count >= 24 else { throw CryptoError.invalidKey("3DES 密钥长度为 \(key.count)") }
            return (CCAlgorithm(kCCAlgorithm3DES), key.prefix(24))
        default:
            throw CryptoError.unsupported(spec.algorithm)
        }
    }

    private static func gcm(encrypt: Bool, key: Data, iv: Data, data: Data, tagLength: Int, aad: Data) throws -> Data {
        guard [16, 24, 32].contains(key.count) else { throw CryptoError.invalidKey("AES 密钥长度为 \(key.count)") }
        let symmetricKey = SymmetricKey(data: key)
        do {
            let nonce = try AES.GCM.Nonce(data: iv)
            if encrypt {
                let box = try AES.GCM.seal(data, using: symmetricKey, nonce: nonce, authenticating: aad)
                return box.ciphertext + box.tag
            }
            guard data.count >= tagLength else { throw CryptoError.failed("密文过短") }
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: data.dropLast(tagLength), tag: data.suffix(tagLength))
            return try AES.GCM.open(box, using: symmetricKey, authenticating: aad)
        } catch let e as CryptoError {
            throw e
        } catch {
            throw CryptoError.failed("GCM: \(error)")
        }
    }

    private static func withOptionalBytes<R>(_ data: Data?, _ body: (UnsafeRawPointer?) -> R) -> R {
        guard let data else { return body(nil) }
        return data.withUnsafeBytes { body($0.baseAddress) }
    }
}


/// 与 Android `android.util.Base64` 标志位一致的编解码


#endif
