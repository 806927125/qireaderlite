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

print("\n\(fail == 0 ? "✅" : "❌") 通过 \(pass) / 失败 \(fail)")
exit(fail == 0 ? 0 : 1)
