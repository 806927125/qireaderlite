import Foundation
import ChaiyueModels
import ChaiyueEngine
import LegadoEngine

// =============================================================================
// 探针 4：**token 管道**（真引擎 + 真源 + 真站方）（2026-11-24）
//
// ⭐⭐⭐⭐⭐ **为什么要有这个探针** ⭐⭐⭐
//   真机症状（书山聚合 v6）：发现页 toast「**Token 格式错误**」⭐⭐⭐
//   ⇒ 站方服务器明确说：收到的 `x-novel-token` **不是合法 base64** ⭐⭐⭐
//     （实测站方判定表：空 →「请先登录」/ 带引号 →「Token 格式错误」/
//       长度不对 →「Token 长度不正确」/ 其它 →「Token 无效或已失效」）⭐⭐⭐
//
//   ⇒ **候选只有两类**（本探针一次分开）⭐⭐⭐
//     A. **管道坏**：`source.getLoginHeader()` 返回的**不是原样字符串**
//        （例如变成 JS 对象 ⇒ `String(...)` = "[object Object]" ⇒ 不是 base64）⭐⭐⭐
//     B. **登录没写进去 / 写的不是同一个**：管道是好的，但 loginHeader 里是别的东西⭐⭐⭐
//
//   ⇒ 本探针用**真引擎（macOS 有 JSC）+ 真源 + 真站方**逐环取证 ⭐⭐⭐
//     ① 注入一个【合法形态】的 token（12 字节明文 ⇒ 16 字符 base64）
//     ② 看 **JS 侧** `String(source.getLoginHeader())` 是不是逐字相同 ⭐⭐⭐
//     ③ 看站方自己的 `ssh_buildHeaders()` 产出的 `x-novel-token` 是不是逐字相同 ⭐⭐⭐
//     ④ 「重启」（新 WebBook + 同一 store）后还在不在 ⭐⭐⭐
//     ⑤ **拿这些 header 真打站方** ⇒ 看站方怎么说（决定性判据）⭐⭐⭐
//
//   ⚠️⚠️ **为什么 ④ 重要**：轻阅的内存态在进程内是好的，重启后才坏 ⭐⭐⭐
//     ⇒ 「重启往返」是**唯一**能复现用户症状的那个维度 ⭐⭐⭐
// =============================================================================

// ⚠️ 用 `#filePath` 推导仓库根（CI 的 cwd 与本地不同 ⇒ 相对路径不可靠）⭐⭐⭐
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Sources/ChaiyueProbe4
    .deletingLastPathComponent()   // Sources
    .deletingLastPathComponent()   // LegadoEngine
    .deletingLastPathComponent()   // 仓库根

let fixturePath = repoRoot.appendingPathComponent("test/fixtures/shushan-adapted.json").path

print("=== 探针 4 · token 管道（真引擎 + 真源 + 真站方）===")

var failures = 0
func expect(_ ok: Bool, _ label: String, _ detail: String = "") {
    if ok { print("  ✅ \(label)\(detail.isEmpty ? "" : " — \(detail)")") }
    else { failures += 1; print("  ❌ \(label)\(detail.isEmpty ? "" : " — \(detail)")") }
}
/// 打印一个字符串的「可归因指纹」：长度 + 前 24 字符 + 前 12 字节的 hex ⭐⭐⭐
func fingerprint(_ s: String?) -> String {
    guard let s else { return "(nil)" }
    let head = String(s.prefix(24))
    let hex = s.prefix(12).map { String(format: "%02x", $0.asciiValue ?? 0) }.joined()
    return "len=\(s.count) head=[\(head)] hex=[\(hex)]"
}

// ─────────────────────────────────────────────────────────────────────────────
// ① **宿主同款 store 接线**（内存版，逐字照抄 `ChaiyueRuntime.makeStore` 的槽语义）⭐⭐⭐
// ─────────────────────────────────────────────────────────────────────────────
print("\n[①] 宿主同款 store 接线（内存槽）")

final class HostSlots {
    var stationVariable: [String: String] = [:]     // sourcevariable.
    var sourceVars: [String: [String: String]] = [:] // sourcevars.（一个 JSON map ⇒ 每项一项）
    var loginInfo: [String: String] = [:]            // sourcelogin.
    var loginHeader: [String: String] = [:]          // sourceheader.
    var deviceID: String?                            // qr.chaiyue.deviceID
    var plain: [String: String] = [:]                // qr.chaiyue.cache.
}

let slots = HostSlots()

let store = ChaiyueKeyValueStore(
    readSlot: { slot in
        switch slot {
        case .stationVariable(let k):
            let v = slots.stationVariable[k] ?? ""; return v.isEmpty ? nil : v
        case .sourceVar(let k, let n):
            let v = slots.sourceVars[k]?[n] ?? ""; return v.isEmpty ? nil : v
        case .loginInfo(let k):
            let v = slots.loginInfo[k] ?? ""; return v.isEmpty ? nil : v
        case .loginHeader(let k):
            let v = slots.loginHeader[k] ?? ""; return v.isEmpty ? nil : v
        case .deviceID:
            return slots.deviceID
        case .plainCache(let k), .opaque(let k):
            return slots.plain[k]
        }
    },
    writeSlot: { slot, value in
        switch slot {
        case .stationVariable(let k):
            slots.stationVariable[k] = value ?? ""
        case .sourceVar(let k, let n):
            var m = slots.sourceVars[k] ?? [:]
            if let value, !value.isEmpty { m[n] = value } else { m.removeValue(forKey: n) }
            slots.sourceVars[k] = m
        case .loginInfo(let k):
            slots.loginInfo[k] = value ?? ""
        case .loginHeader(let k):
            slots.loginHeader[k] = value ?? ""
        case .deviceID:
            slots.deviceID = value
        case .plainCache(let k), .opaque(let k):
            slots.plain[k] = value ?? ""
        }
    },
    listAllSourceVars: {
        var out: [(sourceKey: String, name: String)] = []
        for (k, m) in slots.sourceVars { for n in m.keys { out.append((sourceKey: k, name: n)) } }
        return out
    },
    listPlainCacheKeys: { _ in [] },
    loginInfoToChaiyue: { $0 },
    loginInfoFromChaiyue: { $0 }
)

// ─────────────────────────────────────────────────────────────────────────────
// ② 读真源
// ─────────────────────────────────────────────────────────────────────────────
guard let data = FileManager.default.contents(atPath: fixturePath) else {
    print("FAIL: 读不到 fixture：\(fixturePath)"); exit(2)
}
let source: BookSource
do {
    let obj = try JSONSerialization.jsonObject(with: data)
    let dict: [String: Any]
    if let arr = obj as? [[String: Any]] { dict = arr[0] }
    else if let one = obj as? [String: Any] { dict = one }
    else { print("FAIL: 顶层既不是数组也不是对象"); exit(2) }
    source = try JSONDecoder().decode(BookSource.self,
                                      from: try JSONSerialization.data(withJSONObject: dict))
    print("  书源：\(source.bookSourceName)  fixture=\(data.count) 字节")
} catch {
    print("FAIL: 解码失败：\(error)"); exit(2)
}

// 合法形态的 token：12 字节明文 ⇒ 16 字符 base64（站方实测：明文 12 字节才过「长度」关）⭐⭐⭐
let TOKEN = "QUJDREVGR0hJSktM"      // base64("ABCDEFGHIJKLM")
let TOKEN_PLAIN = "ABCDEFGHIJKLM"

func makeEnv() -> SourceEnvironment {
    // ⭐ 新建 environment = 「新进程」的内存态（CacheStore 的内存缓存是新的）
    //   ⇒ 但 store 是同一个 ⇒ 读到的只可能是**落盘的值** ⇒ 这就是「重启」⭐⭐⭐
    SourceEnvironment(store: store, deviceID: "probe-device-0001")
}

// ─────────────────────────────────────────────────────────────────────────────
// ③ 注入 token（走站方那条路：`source.putLoginHeader(...)`）⭐⭐⭐
// ─────────────────────────────────────────────────────────────────────────────
print("\n[③] 注入 token（`source.putLoginHeader`）—— 注入值 = \(TOKEN)（明文 \(TOKEN_PLAIN)）")
let web = WebBook(source: source, environment: makeEnv())
do {
    _ = try await web.evalJS("source.putLoginHeader('\(TOKEN)')")
} catch {
    print("  ❌ putLoginHeader 抛错：\(error)"); failures += 1
}
// 宿主槽里落的东西（= 宿主 UserDefaults 的 sourceheader.<url>）⭐⭐⭐
print("  宿主槽落盘值：\(fingerprint(slots.loginHeader[source.bookSourceUrl]))")
expect(slots.loginHeader[source.bookSourceUrl] == TOKEN, "落盘值与注入值逐字相同",
       fingerprint(slots.loginHeader[source.bookSourceUrl]))

// ─────────────────────────────────────────────────────────────────────────────
// ④ **JS 侧**看到的值（⭐ 关键：上游测试只断言了 Swift 侧，没断言 JS 侧）⭐⭐⭐
// ─────────────────────────────────────────────────────────────────────────────
print("\n[④] JS 侧 `source.getLoginHeader()`")
let jsType = (try? await web.evalJS("typeof source.getLoginHeader()")) ?? "?"
let jsValue = (try? await web.evalJS("String(source.getLoginHeader())")) ?? "?"
print("  typeof = \(jsType)")
print("  String() = \(fingerprint(jsValue))")
expect(jsType == "string", "getLoginHeader 返回的是 JS **字符串**", "typeof=\(jsType)")
expect(jsValue == TOKEN, "JS 侧取值与注入值逐字相同", fingerprint(jsValue))

// ─────────────────────────────────────────────────────────────────────────────
// ⑤ **站方自己的** `ssh_buildHeaders()` ⇒ 看它真正会发出去的 `x-novel-token` ⭐⭐⭐
// ─────────────────────────────────────────────────────────────────────────────
print("\n[⑤] 站方 `ssh_buildHeaders.call(this)` 的真实产物")
let headersJSON = (try? await web.evalJS("JSON.stringify(ssh_buildHeaders.call(this))")) ?? "{}"
var headers: [String: String] = [:]
if let obj = try? JSONSerialization.jsonObject(with: Data(headersJSON.utf8)) as? [String: Any] {
    for (k, v) in obj { headers[k] = String(describing: v) }
}
print("  x-novel-token  = \(fingerprint(headers["x-novel-token"]))")
print("  x-novel-public = \(fingerprint(headers["x-novel-public"]))")
print("  x-novel-deviceid = \(fingerprint(headers["x-novel-deviceid"]))")
expect(headers["x-novel-token"] == TOKEN, "x-novel-token 与注入值逐字相同",
       fingerprint(headers["x-novel-token"]))

// ─────────────────────────────────────────────────────────────────────────────
// ⑥ **重启往返**（新 environment + 新 WebBook + 同一 store）⭐⭐⭐
// ─────────────────────────────────────────────────────────────────────────────
print("\n[⑥] 「重启」后（全新 WebBook + 同一 store ⇒ 只能读到落盘的值）")
let web2 = WebBook(source: source, environment: makeEnv())
let afterType = (try? await web2.evalJS("typeof source.getLoginHeader()")) ?? "?"
let afterValue = (try? await web2.evalJS("String(source.getLoginHeader())")) ?? "?"
print("  typeof = \(afterType)")
print("  String() = \(fingerprint(afterValue))")
expect(afterValue == TOKEN, "重启后 token 还在且逐字相同", fingerprint(afterValue))
let afterHeaders = (try? await web2.evalJS("JSON.stringify(ssh_buildHeaders.call(this))")) ?? "{}"
var afterH: [String: String] = [:]
if let obj = try? JSONSerialization.jsonObject(with: Data(afterHeaders.utf8)) as? [String: Any] {
    for (k, v) in obj { afterH[k] = String(describing: v) }
}
expect(afterH["x-novel-token"] == TOKEN, "重启后 x-novel-token 逐字相同",
       fingerprint(afterH["x-novel-token"]))

// ─────────────────────────────────────────────────────────────────────────────
// ⑦ **真打站方**（用站方自己的 `ssh_postJson` ⇒ 连签名算法一起验）⭐⭐⭐
// ─────────────────────────────────────────────────────────────────────────────
print("\n[⑦] 真打站方 /api/discover（用站方自己的 ssh_postJson ⇒ 含签名）")
let stationRaw = (try? await web2.evalJS("""
(function () {
  try {
    var d = ssh_postJson.call(this, '/api/discover', {
      source: '番茄小说', gender: 'boy', logins: '', tab: 'novel', selected_items: ''
    });
    return JSON.stringify({ code: d && d.code, message: d && d.message });
  } catch (e) {
    return JSON.stringify({ error: String(e) });
  }
})()
""")) ?? "{}"
print("  站方回话：\(stationRaw)")
if let obj = try? JSONSerialization.jsonObject(with: Data(stationRaw.utf8)) as? [String: Any] {
    let msg = obj["message"] as? String ?? ""
    let err = obj["error"] as? String ?? ""
    if !err.isEmpty {
        expect(false, "站方请求没抛错", err)
    } else if msg.contains("Token 格式错误") {
        expect(false, "站方说「Token 格式错误」⇒ **管道把 token 弄坏了**", msg)
    } else if msg.contains("Token 无效或已失效") {
        expect(true, "站方说「Token 无效或已失效」⇒ **管道是通的**（token 形态/长度/签名都对）", msg)
    } else if msg.contains("长度不正确") {
        expect(false, "站方说「Token 长度不正确」⇒ token 形态对但长度不对", msg)
    } else if msg.contains("请先登录") {
        expect(false, "站方说「请先登录」⇒ **请求里根本没带 token**", msg)
    } else {
        print("  ⚠️ 站方回了别的消息：\(msg)（可能站方状态变了）")
    }
}

print("\n=== 探针 4 结束：失败 \(failures) 项 ===")
exit(failures == 0 ? 0 : 1)
