#!/usr/bin/env swift
// 轻阅原生能力（Core/LegadoCompat.swift）的**真跑**测试
//
// 跑法：swift test/legado-compat-test.swift
//
// 为什么单独一个文件：`Core/` 是纯 Foundation 层（不 import WebKit/SwiftUI），
// 所以在 Linux 沙盒里能**真编真跑** —— 改完 3 秒出结果，不用等 CI。
//
// 验的是站方拼会员卡片真正依赖的语义：
//     java.timeFormat(res.register_time*1000).padEnd(20,"\t")
//     java.timeFormat(new Date()).slice(0,10) == java.timeFormat(res.last_read_time*1000).slice(0,10)

import Foundation

var pass = 0
var fail = 0

func ok(_ cond: Bool, _ label: String) {
    if cond {
        pass += 1
        print("  ✓ \(label)")
    } else {
        fail += 1
        print("  ✗ \(label)")
    }
}

func eq<T: Equatable>(_ a: T, _ b: T, _ label: String) {
    if a == b {
        pass += 1
        print("  ✓ \(label)")
    } else {
        fail += 1
        print("  ✗ \(label)  实际=\(a) 期望=\(b)")
    }
}

print("=== 1. timeFormat：数字 → 格式化字符串（Legado 语义）===")
// ⚠️ 期望值**现算**，不手敲（手敲的时间戳错过一次）：
//    用 Calendar 独立算一遍「本地时区的 yyyy-MM-dd HH:mm:ss」，
//    跟 LegadoCompat 用 DateFormatter 算出来的**交叉比对**。
func expectedLocal(_ ms: Int64) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = .current
    let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                from: Date(timeIntervalSince1970: Double(ms) / 1000.0))
    func p(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
    return "\(c.year ?? 0)-\(p(c.month ?? 0))-\(p(c.day ?? 0)) "
         + "\(p(c.hour ?? 0)):\(p(c.minute ?? 0)):\(p(c.second ?? 0))"
}

let sample = Int64(1_799_990_076_000)
let formatted = LegadoCompat.TimeFormat.format(ms: sample)
let want = expectedLocal(sample)
eq(formatted, want, "格式化结果跟独立算法一致 → \(formatted)")
ok(formatted.count == 19, "格式是 19 个字符（yyyy-MM-dd HH:mm:ss）")
// .slice(0,10) 必须是日期（站方拿它跟今天比）
eq(String(formatted.prefix(10)).count, 10, "slice(0,10) 拿到 10 个字符（站方要比日期）")
eq(String(formatted.prefix(10)), String(want.prefix(10)), "slice(0,10) 就是 yyyy-MM-dd")
// 本地时区自洽：同一个毫秒，格式出来的日期 == 该毫秒在本地的年月日
var cal = Calendar(identifier: .gregorian)
cal.timeZone = .current
let comps = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: 1_799_990_076.0))
ok(String(formatted.prefix(4)) == String(comps.year ?? 0),
   "年份跟 Calendar 对得上（时区处理没错）")

print("\n=== 2. timeFormat：统一入口按输入形态分流 ===")
// 数字 → 字符串
let viaNumber = LegadoCompat.TimeFormat.apply("1799990076000")
ok(viaNumber is String, "纯数字 → 返回 String（站方要 .padEnd）")
ok((viaNumber as? String) == want, "纯数字 → 格式化成同一个字符串")
// 10 位以内的纯数字当秒
let viaSeconds = LegadoCompat.TimeFormat.apply("1799990076")
ok(viaSeconds is String, "10 位纯数字（秒）→ 也返回 String")
// 日期字符串 → 毫秒数
let viaString = LegadoCompat.TimeFormat.apply("2017-04-24 14:16:34")
ok(viaString is Int64, "日期字符串 → 返回毫秒数（语料当章节时间戳用）")
eq(viaString as? Int64, 1_493_043_394_000, "UTC 解释（跟旧 JS 的 Date.UTC 一致）")
// 空 → 空串
eq(LegadoCompat.TimeFormat.apply("") as? String, "", "空输入 → 空串")

print("\n=== 3. timeFormat：解析各种站方格式 ===")
eq(LegadoCompat.TimeFormat.parse("2017-04-24"), 1_492_992_000_000, "yyyy-MM-dd")
eq(LegadoCompat.TimeFormat.parse("2017/04/24"), 1_492_992_000_000, "yyyy/MM/dd")
eq(LegadoCompat.TimeFormat.parse("2017-04-24T14:16:34"), 1_493_043_394_000, "ISO 带 T")
eq(LegadoCompat.TimeFormat.parse("不是日期"), 0, "解析不了给 0（不抛）")
eq(LegadoCompat.TimeFormat.parse("1492416994"), 1_492_416_994_000, "10 位数字当秒")

print("\n=== 4. cache（Swift 侧 KV）===")
let key = "test-\(Int(Date().timeIntervalSince1970))"
LegadoCompat.Cache.put(key, "值-A")
eq(LegadoCompat.Cache.get(key), "值-A", "put 之后能读回来")
LegadoCompat.Cache.put(key, "值-B")
eq(LegadoCompat.Cache.get(key), "值-B", "重复 put 覆盖")
LegadoCompat.Cache.remove(key)
eq(LegadoCompat.Cache.get(key), "", "remove 之后读不到")

print("\n=== 5. 同步通道分发 ===")
let r1 = LegadoCompat.handle(fn: "timeFormat", args: ["input": "1799990076000"])
eq(r1["ok"] as? Bool, true, "timeFormat 分发 ok")
eq(r1["value"] as? String, want, "timeFormat 分发拿到格式化字符串 → \(r1["value"] ?? "nil")")
let r2 = LegadoCompat.handle(fn: "cachePut", args: ["key": "k1", "value": "v1"])
eq(r2["ok"] as? Bool, true, "cachePut 分发 ok")
eq(LegadoCompat.handle(fn: "cacheGet", args: ["key": "k1"])["value"] as? String, "v1", "cacheGet 读得到")
LegadoCompat.handle(fn: "cacheRemove", args: ["key": "k1"])
eq(LegadoCompat.handle(fn: "cacheGet", args: ["key": "k1"])["value"] as? String, "", "cacheRemove 之后读不到")
let r3 = LegadoCompat.handle(fn: "没这能力", args: [:])
eq(r3["ok"] as? Bool, false, "未知能力 → ok=false（不是崩）")


print("\n=== 6. 登录检测的响应分类（三档必须分清）===")
// ⚠️ 真机踩过：服务器 502 + <!DOCTYPE html> → 以前被报成「未登录」
//    → 用户以为白登了。5xx / 非 JSON 一律算「服务器异常」。

// ① 有 id → 已登录
let okBody = Data(#"{"id":6044,"nickname":"流云","email":"a@b.com"}"#.utf8)
if case .loggedIn(let info) = LegadoCompat.classify(code: 200, data: okBody) {
    ok((info["id"] as? Int) == 6044, "有 id → 判为已登录")
} else {
    ok(false, "有 id → 判为已登录")
}

// ② 服务器明确回 JSON 说没密钥 → 未登录
let noKey = Data(#"{"code":-1,"msg":"请求参数中未找到密钥"}"#.utf8)
if case .notLoggedIn(let msg) = LegadoCompat.classify(code: 400, data: noKey) {
    ok(msg.contains("未找到密钥"), "JSON 说没密钥 → 判为未登录")
} else {
    ok(false, "JSON 说没密钥 → 判为未登录")
}

// ③ 密钥无效（数据库查询失败）→ 也是未登录
let badKey = Data(#"{"code":-1,"msg":"数据库查询失败"}"#.utf8)
if case .notLoggedIn = LegadoCompat.classify(code: 400, data: badKey) {
    ok(true, "密钥无效 → 判为未登录")
} else {
    ok(false, "密钥无效 → 判为未登录")
}

// ④ 502 → 服务器异常（**不是**未登录！）
let html = Data("<!DOCTYPE html><html>...</html>".utf8)
if case .serverError(let msg) = LegadoCompat.classify(code: 502, data: html) {
    ok(msg.contains("502"), "502 → 判为服务器异常")
} else {
    ok(false, "502 → 判为服务器异常")
}

// ⑤ 200 但返回 HTML → 服务器异常
if case .serverError = LegadoCompat.classify(code: 200, data: html) {
    ok(true, "200 但不是 JSON → 判为服务器异常")
} else {
    ok(false, "200 但不是 JSON → 判为服务器异常")
}

print("\n=== 7. loginHeader 解析（栖阅机制）===")
// 格式：`名称: 值`，一行一个 → 注入到每次请求头
eq(LegadoCompat.parseLoginHeader("Cookie: sessionid=ABC").count, 1, "解析出 1 个头")
eq(LegadoCompat.parseLoginHeader("Cookie: sessionid=ABC").first?.0, "Cookie", "头名是 Cookie")
eq(LegadoCompat.parseLoginHeader("Cookie: sessionid=ABC").first?.1, "sessionid=ABC", "头值是 sessionid")
eq(LegadoCompat.parseLoginHeader("X-A: 1\nX-B: 2").count, 2, "多行能解析出 2 个头")
eq(LegadoCompat.parseLoginHeader("X-A: 1\nX-B: 2").last?.1, "2", "第二个头的值")
eq(LegadoCompat.parseLoginHeader("").count, 0, "空串 → 没有头")
eq(LegadoCompat.parseLoginHeader("没有冒号").count, 0, "没有冒号的行 → 跳过")
eq(LegadoCompat.parseLoginHeader("  Cookie : x  ").first?.0, "Cookie", "名字两边空格会去掉")

print("\n=== 8. 番茄 sessionid 别名（站方老正则只认 sessionid=）===")
// 2026-10-21 真机：番茄登了，发现页还是「已过期」
//   站方：var match = rawCookie.match(/sessionid=[^;]+/);  ← 只认 sessionid=
//   番茄新版发的键是 `sessionid_ss` ⇒ 匹配失败 ⇒ 一直 toast「未登陆番茄账号」
eq(LegadoCompat.fanqieSessionAlias("sessionid_ss=ABC123"), "sessionid_ss=ABC123; sessionid=ABC123",
   "只有 sessionid_ss ⇒ 补一条 sessionid 别名")
eq(LegadoCompat.fanqieSessionAlias("sessionid_ss=ABC123; other=1"), "sessionid_ss=ABC123; other=1; sessionid=ABC123",
   "夹在中间的 sessionid_ss 也能抠出来")
eq(LegadoCompat.fanqieSessionAlias("sessionid=REAL"), "sessionid=REAL",
   "已有标准 sessionid ⇒ 不动（别覆盖站方真正认的那个）")
eq(LegadoCompat.fanqieSessionAlias("sessionid_ss=A; sessionid=B"), "sessionid_ss=A; sessionid=B",
   "两个都有 ⇒ 不动")
eq(LegadoCompat.fanqieSessionAlias("qttoken=XYZ"), "qttoken=XYZ",
   "没有 sessionid 系 ⇒ 不动")
eq(LegadoCompat.fanqieSessionAlias(""), "", "空串 → 空串")
eq(LegadoCompat.fanqieSessionAlias("sessionid_ss="), "sessionid_ss=",
   "值为空 ⇒ 不补")
eq(LegadoCompat.fanqieSessionAlias("sessionid_ss=YWJjZA=="),
   "sessionid_ss=YWJjZA==; sessionid=YWJjZA==",
   "base64 结尾的 = padding 不能被截断")
ok(LegadoCompat.isFanqieHost("fanqienovel.com"), "fanqienovel.com 是番茄域")
ok(LegadoCompat.isFanqieHost(".fanqienovel.com"), "带前导点的也是")
ok(LegadoCompat.isFanqieHost("api5-normal-sinfonlinec.fqnovel.com"), "fqnovel.com 也是番茄域")
ok(!LegadoCompat.isFanqieHost("v5.langge.uk"), "大灰狼自己的域不是番茄域")


// ── ⭐⭐⭐ cookie 快照解析（2026-10-24 真机栽的：登录 cookie 送不到新引擎）────
let ck = LegadoCompat.cookiePairs(from: ["v5.langge.uk": "qttoken=abc; sessionid=YWJjZA=="])
eq(ck.count, 2, "快照里的两条 cookie 都要拆出来")
eq(ck.first?.name ?? "", "qttoken", "第一条是 qttoken")
eq(ck.last?.value ?? "", "YWJjZA==", "⭐ 值里的 base64 padding `=` 不能被截断")
eq(ck.last?.host ?? "", "v5.langge.uk", "host 要原样")
eq(LegadoCompat.cookiePairs(from: ["h": "novalue"]).count, 0, "没有 `=` 的要跳过")
eq(LegadoCompat.cookiePairs(from: ["": "a=b"]).count, 0, "空 host 要跳过")
eq(LegadoCompat.cookiePairs(from: ["h": "=v"]).count, 0, "空 name 要跳过")
eq(LegadoCompat.cookiePairs(from: ["h": "a=b; ; c=d"]).count, 2, "空的分段要跳过")

print("\n\(fail == 0 ? "✅" : "❌") 通过 \(pass) / 失败 \(fail)")
exit(fail == 0 ? 0 : 1)
