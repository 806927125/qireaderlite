import Foundation

// ⭐⭐⭐⭐⭐ **登录头（token）的「指纹」工具**（2026-11-24 真机「Token 格式错误」实证）⭐⭐⭐⭐⭐
//
// ⚠️⚠️⚠️ **为什么要有这个** ⭐⭐⭐
//   真机症状：书山聚合 v6 的发现页 toast「**Token 格式错误**」⭐⭐⭐
//   ⇒ 我拿沙盒直连站方实测了它对 token 的**完整判定表** ⭐⭐⭐：
//     · token 缺失/空      → 「非法请求，请先登录」
//     · **token 非 base64** → 「**Token 格式错误**」⭐⭐⭐（带引号也算！）
//     · token 长度不对      → 「Token 长度不正确」
//     · 其余（库里没有/签名不符/时间戳旧）→ 「Token 无效或已失效」
//   ⇒ 所以「Token 格式错误」**只可能**是「我们发出去的 token 不是合法 base64」⭐⭐⭐
//   ⇒ 而「token 为什么不是 base64」只有两种可能 ⭐⭐⭐：
//     A. 存进去时就带了引号 / 被 JSON 编码过（**落盘层**）
//     B. JS 侧读出来时形态变了（**引擎层**：`String(source.getLoginHeader())`）
//   ⇒ 本文件给**落盘层**一个可判定的指纹 ⇒ 真机一眼就能分开 A/B ⭐⭐⭐
//
// ⭐⭐⭐ **安全**：**不打印 token 内容**（只打长度/是否 base64/是否带引号）⭐⭐⭐
//   （日志会落盘 ⇒ 绝不能把凭据写进去）
enum TokenFingerprint {

    /// ⭐⭐⭐ **是不是合法 base64**（标准字母表 + URL 字母表都认）⭐⭐⭐
    static func isBase64(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        // ⭐ 允许的字符：标准（+/）与 URL 安全（-_）两种字母表 + 末尾补位 =
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/-_=")
        guard t.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        // ⭐ 标准 base64 的长度必是 4 的倍数（站方的 token 是 12 字节 ⇒ 16 字符）
        guard t.count % 4 == 0 else { return false }
        if Data(base64Encoded: t) != nil { return true }
        // ⭐ URL 安全字母表 ⇒ 归一化后再试一次
        let norm = t.replacingOccurrences(of: "-", with: "+")
                       .replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: norm) != nil
    }

    /// ⭐⭐⭐ **一行指纹**（**不含 token 内容**）⭐⭐⭐
    static func describe(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "长度=0 （空 ⇒ 站方会回「请先登录」）" }
        let quoted = raw.hasPrefix("\"") && raw.hasSuffix("\"")
        let b64 = isBase64(raw)
        var s = "长度=\(raw.count) base64=\(b64 ? "是" : "否")"
        if quoted { s += " ⚠️**带引号**（站方会回「Token 格式错误」）" }
        if !b64 && !quoted { s += " ⚠️**不是合法 base64**（站方会回「Token 格式错误」）" }
        return s
    }

    /// ⭐⭐⭐ **一句话结论**（给日志用：直接说站方会怎么回）⭐⭐⭐
    static func verdict(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "无 token ⇒ 站方会回「非法请求，请先登录」" }
        if isBase64(raw) { return "token 形态正常 ⇒ 若站方仍报错 ⇒ 是 token 本身失效/签名不符" }
        return "token 不是合法 base64 ⇒ 站方必然回「Token 格式错误」⭐⭐⭐"
    }
}
