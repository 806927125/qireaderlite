# AnalyzeRule 语义对照：栖阅规格 ⟷ 轻阅老引擎（产品默认） ⟷ legado-engine（自研回退）

> 2026-11-18 · 依据 = 栖阅 2027.01.01 二进制反推规格（`栖阅引擎源码/规格/栖阅引擎反推/02-规则语法规格.md` + 15 篇 `AnalyzeRule+*.md`）
> + 整链对拍四环实测（同一份 fixture、同一份输入）
>
> **三列引擎的身份**：
> · **栖阅** = 用户真机在用的宿主（**语义权威**）
> · **轻阅老引擎** = `QiReaderLite/Resources/engine/*.js`（WKWebView，**产品默认**，`EngineMode.webView`）
> · **legado-engine** = 自研 Swift 引擎（**回退**，`EngineMode.swiftEngine`）

---

## 0. 本轮结论（一句话）

> **两套引擎在整链上已经「等价」**（分类 439=439 / 详情逐字一致 / 目录 3091=3091 / 正文逐字一致）
> ⇒ ⇒ **「换引擎更强」的收益不在规则求值层**，而在架构层（进程隔离 / 内存 / jetsam）。
> ⇒ ⇒ 剩下的差异**全是「能力覆盖」问题**（栖阅有、两边没有），不是「同一件事两种做法」。

---

## 1. 规则模式（RuleMode）

| 模式 | 栖阅（规格） | 轻阅老引擎 | legado-engine | 处置 |
|---|---|---|---|---|
| `css` | ✅ SwiftSoup | ✅ | ✅ | — |
| `xpath` | ✅ **真 XPath（libxml2）** | ✅ **真 XPath**（`document.evaluate`） | ⚠️ **自研子集**（308 行，覆盖 125 源实测用法） | **语义不同**：子集外表达式会失败 ⇒ 只影响回退引擎 ⇒ 见 §6 |
| `json` | ✅ 自研 JsonElement + PathToken | ✅（Sextant 兜底 + 手写） | ✅（Sextant vendor + 手写兜底） | — |
| `js` | ✅ JavaScriptCore | ✅ WKWebView | ✅ JSC / Node | — |
| `webJs` | ✅ **栖阅比 Legado 多这一种** | ⚠️ 有 `ruleContent.webJs`（字段级，同一引擎里跑 JS 取 HTML） | ⛔ 无 | 栖阅是**规则模式**，我们是**字段** ⇒ 语义不同（低频） |
| `regex` | ✅ | ✅ | ✅ | — |
| `variable` | ✅（取变量） | ⛔ 无独立模式（走 `@get:`） | ⚠️ 走 `@get:` / `pureVarKey` | 语义近似 |
| `defaultRule` | ✅（纯文本/直接返回） | ✅（`T.EMPTY` + 字面量分支） | ✅（`.empty` + 字面量分支） | — |

> ⚠️ **`@js:` 前缀 ⇒ 整条当 JS**（不按 `||`/`&&` 拆、不取尾部）：栖阅 ✅ / legado-engine ✅ / **轻阅老引擎 ⛔（本轮已修）**

---

## 2. JS 求值语义

| 行为 | 栖阅（规格原文） | 轻阅老引擎 | legado-engine | 备注 |
|---|---|---|---|---|
| 求值形态 | `Function(__script + "\n;return (typeof result !== 'undefined') ? result : undefined;")` | `new Function(..., 'return eval(__qrCode);')` + 表达式/函数体兜底 | `JSEvalShape`（三形态，**Swift 侧算好**） | 三边等价 |
| 语法错兜底 | 退回「整段当表达式」 | 表达式 → 函数体（两次） | 表达式 → 函数体 | 等价 |
| `var result = …` 优先 | ✅ | ✅ | ✅ | 等价 |
| 顶层 `return` | 不需要（末行表达式） | 支持（第三形态） | 支持 | 比栖阅更宽松 |
| **JS 全局态治理** | ✅ `recordBaseGlobalKeysIfNeeded` / `restoreMutatedBaseGlobals` / `purgeUnexpectedGlobals` | ✅（「全局治理」日志 + 切源还原） | ✅（`markGlobalsAsBaseline`） | 等价 |

---

## 3. ⭐ `result` 的绑定（本轮修的第一处）

| 形态 | 栖阅（规格） | 轻阅老引擎 | legado-engine |
|---|---|---|---|
| 页面级基准 | 页原文 | 页原文 | 页原文 |
| 条目级基准 | 那条记录 | 那条记录 | 那条记录 |
| **JSON 对象基准** | ✅ `makeJavaScriptJSONObjectValue(jsonString)`：**对象 + 覆写 `toString`/`valueOf` 回到原始 JSON 文本** | ✅ **本轮已修**（`init` 的 JSON 输出挂 toString/valueOf） | ⛔ **缺口**：`.json` 基准绑裸对象 ⇒ `String(result)` = `[object Object]` |

> **为什么这条要命**：站方详情字段普遍写 `JSON.parse(String(result))`
> ⇒ 裸对象 ⇒ parse 抛 ⇒ **整本书详情字段全空**（不是某个字段，是一整片）。
> ⇒ 栖阅能同时满足 `result.book_id`（对象）与 `String(result)`（原始文本）⇒ **必须做这层桥**。

---

## 4. URL 选项（`url,{JSON}`）

栖阅反射出来的**选项键全集（17 个）**：`method` `body` `headers` `initialHeaderMap` `requestContextVariables` `charset` `useWebView` `webJs` `bodyJs` `sourceRegex` `overrideUrlRegex` `retry` `proxy` `serverID` `dnsIp` `requestTimeout` `webViewDelayTime` `type`

| 引擎 | 已支持 | 缺 |
|---|---|---|
| 轻阅老引擎 | `method` `headers` `body` `timeout` `retry` `proxy` | 其余 |
| legado-engine | `method` `headers` `body`（+ 默认超时） | 其余 |

> ⚠️ **`headers` 是替换式**（挂上去会顶掉源级 header）—— 三边一致，别改。

---

## 5. 书源字段覆盖

| 规则 | 字段 | 栖阅 | 轻阅老引擎 | legado-engine |
|---|---|---|---|---|
| `ruleBookInfo` | name/author/intro/kind/lastChapter/coverUrl/wordCount | ✅ | ✅ | ✅ |
| | `init` / `tocUrl` | ✅ | ✅ | ✅ |
| | `updateTime` | ✅ | ⛔ | ⚠️（有 1 处引用，未成体系） |
| | `canReName` / `downloadUrls` / `preUpdateJs` | ✅ | ⛔ | ⛔ |
| `ruleToc` | `chapterList` / `chapterUrl` / `chapterName` | ✅ | ✅ | ✅ |
| | `nextTocUrl` | ✅ | ✅ | ✅ |
| | `formatJs` / `isVolume` / `isVip` / `isPay` / `updateTime` / `preUpdateJs` | ✅ | ⛔ | ⚠️ `isVip`（6 处引用） |
| `ruleContent` | `content` / `title` / `nextContentUrl` / `webJs` | ✅ | ✅ | ✅ |
| | `subContent` / `replaceRegex` / `sourceRegex` / `imageStyle` / `imageDecode` / `payAction` / `callBackJs` | ✅ | ⛔（`replaceRegex` 无） | ⚠️ `replaceRegex`(2) / `sourceRegex`(1) / `imageStyle`(2) |
| `ruleReview`（段评，**安卓没有**） | urlRule/listRule/contentRule/… | ✅ | ⛔ | ⛔ |

---

## 6. 其它（Filter / XPath / 全局）

| 项 | 栖阅 | 轻阅老引擎 | legado-engine |
|---|---|---|---|
| **Filter 表达式**（栖阅自研，Legado 没有） | ✅ 自研 `FilterCompiler` | ✅ `sextant-filter.js` | ✅ **Sextant vendor**（MIT） |
| XPath 覆盖 | 真 XPath（libxml2 / Kanna） | 真 XPath（`document.evaluate`） | ⚠️ 自研子集 |
| `useWebView` / `webJs` 请求 | ✅ | ❌ | ❌ |

> ⭐ **Kanna 评估结论（2026-11-18）**：
> **产品默认引擎（WKWebView）已经是真 XPath** ⇒ `webJs`/Kanna 只影响**回退引擎** ⇒
> ⇒ **暂不搬 Kanna**（带 libxml2 C 源码，沙盒编不了、体积大）⇒
> ⇒ 等差集里**真的出现 XPath 子集外的表达式**再搬（触发条件明确）。

---

## 7. 本轮实际改动

| # | 引擎 | 改动 | 影响 |
|---|---|---|---|
| 1 | 轻阅老引擎 | `rule-analyzer.js`：**`@js:` 前缀 ⇒ 不取尾部**（`isJsPrefixed`） | ⭐ **聚合源 6 个详情字段从「全空」变「有值」**（真机真凶） |
| 2 | 轻阅老引擎 | `engine.js`：**init 的 JSON 输出挂 `toString`/`valueOf`** ⇒ `String(result)` 回到原始文本 | ⭐ 站方 `JSON.parse(String(result))` 能用 |
| 3 | legado-engine | `NodeJSExecutor`：**宿主对象（source/book/chapter）通道** + jsLib 字面量调用预计算 | ⭐ **沙盒后端 ≠ 真机后端** ⇒ 对拍不再「两边都空」（假绿） |
| 4 | legado-engine | `NodeJSExecutor`：**jsLib 里的 `source.get(...)` 也预计算** | ⭐ 解锁态在沙盒里读得到 |

---

## 8. 对拍台现状（可复现）

| 环 | 输入 | Swift | 老引擎 | 差集 |
|---|---|---|---|---|
| exploreKinds | `novelhub-menu.json` | 439 | 439 | **0** |
| bookInfo | `novelhub-detail.json` | 天渊 / 沐潇三生 / 289 字 | 同 | **0（逐字）** |
| toc | `novelhub-toc.json` | 3091 章 | 3091 章 | **0** |
| content | `novelhub-content.json` | 逐字一致 | 逐字一致 | **0** |

> ⚠️ 「长度差 39」是**计数口径**（Swift 数**字素簇**，oracle 数**码点**）⇒ **不是内容差异**。

---

## 9. 待办（按优先级）

1. ⭐ **legado-engine 补 `result` 的 JSON 桥**（§3 唯一缺口）⇒ 与栖阅对齐
2. ⭐ **轻阅出包**（改动 1、2 在产品默认引擎里 ⇒ 必须出包才生效）
3. `ruleContent.replaceRegex` / `ruleToc.formatJs` 等字段补齐（两引擎同步）
4. `webJs` 模式（栖阅独有）—— 观察真实源里有没有用到
5. XPath 子集外表达式 ⇒ 真出现再搬 Kanna

---

## 10. 2026-11-18 晚：拿到 **legado-E 源码** ⇒ 语义口径升级为「源码级」

> 用户决定：「整个搬过来，现在这个引擎不要了」⇒ 于是把 **legado-E**（阅读Sigma = legado 的继承，GPL-3.0，**个人自用不触发分发义务**）拉下来当**源码级底稿**，
> 而**不是**猜规格 ⇒ 这一节把「谁是权威」彻底定死。

### 10.1 权威口径的优先级（重要，别再混）

| 参照物 | 地位 | 理由 |
|---|---|---|
| **栖阅 / 柴阅** | ⭐⭐⭐ **最终权威**（语义） | 柴阅 = 栖阅同构 ⇒ **用户真机在用的就是它** ⇒ 「同源柴阅可以」的标准答案 |
| **legado-E** | ⭐⭐ **结构与底稿**（规则切分/URL 选项/字段清单） | Kotlin 源码可读 ⇒ 比反推规格精确得多 ⇒ 用来**逐条核对** |
| 栖阅的**反推规格** | ⭐ 辅助 | 只有规格没有源码 ⇒ 用来补 legado-E 没有的部分 |

⇒ ⇒ **落地方针：语义按栖阅，结构按 legado-E，缺的部分两边的规格补齐。**

### 10.2 legado-E 源码给出的**正统 Legado 语义**（`model/webBook/BookInfo.kt` + `analyzeRule/AnalyzeRule.kt`）

```kotlin
analyzeRule.setContent(body)                                    // content = 详情页原文
if (infoRule.init.isNotBlank())
    analyzeRule.setContent(analyzeRule.getElement(it))            // ⭐ init 的输出【替换 content】
analyzeRule.getString(infoRule.name)                            // 字段规则以【init 的输出】为基准
```
```kotlin
fun evalJS(jsStr: String, result: Any? = null): Any? {
    bindings["result"] = result        // ⭐ result = 【当前 content】
    bindings["src"]   = content        // ⭐ src   = 【当前 content】（另一个名字）
    ...
}
```

⇒ 三条结论：
1. **init 的输出替换 content** ⇒ 后续字段规则的基准 = init 输出（轻阅两个引擎本来就这么做 ✔）
2. **`result` = 当前 content** ⇒ **不是**「解析后的对象」⇒ `String(result)` 天然就是页面原文
3. **`src` 是 content 的别名** ⇒ 站方也可以用 `src`（轻阅两个引擎**都没有 `src`** ⇒ 缺口 ⭐⭐⭐）

### 10.3 ⭐⭐⭐ **栖阅比 legado-E 多的那一层：JSON 对象的 `toString` 桥**

| | `result` 绑 JSON 对象时 | `String(result)` |
|---|---|---|
| **legado-E**（Rhino 原生对象） | 对象 | `"[object Object]"` ⇒ `JSON.parse` **抛** |
| **栖阅 / 柴阅** | 对象（`makeJavaScriptJSONObjectValue`） | **原始 JSON 文本** ⇒ `JSON.parse` **可用** ✔ |

⇒ ⇒ **这就是「同源柴阅可以、轻阅不行」的第一性解释**：
聚合源的详情字段写的是 `JSON.parse(String(result))` ⇒ **必须有那层桥** ⇒ 轻阅两个引擎都缺 ⇒ 六个详情字段一起空。
⇒ ⇒ 轻阅已补（老引擎 `engine.js` 的 init 输出挂 `toString`/`valueOf`；Swift 引擎 `JSHostAPI.resultBinding`）⭐⭐⭐

⇒ ⇒ ⚠️ **推论**：**照 legado-E 照抄语义会把柴阅的能力再弄丢一次** ⇒ ⇒ 必须「以栖阅为准」。

### 10.4 legado-E 的 **URL 选项全集**（`analyzeRule/AnalyzeUrl.kt` 240~267 行逐项读出）

`method` `headers` `body` `type` **`charset`** **`retry`** **`useWebView`** **`webJs`** **`bodyJs`** `js` **`dnsIp`** **`serverID`** **`webViewDelayTime`** `proxy`
（栖阅再多：`initialHeaderMap` `requestContextVariables` `sourceRegex` `overrideUrlRegex` `requestTimeout`）

⇒ ⇒ 轻阅原来只支持 **3 个**（method/headers/body）⇒ **这就是「同源 A 不行 B 可以」的结构性原因** ⭐⭐⭐
⇒ ⇒ 已移植进 Swift 引擎（`URLBuilder.Built` + `HTTPRequest` 透传 + `PageFetcher` 实现 `retry`），宿主侧实现 `charset` 解码。

### 10.5 legado-E 的 `BookSource` 字段清单（`data/entities/BookSource.kt`）

⇒ `ruleBookInfo`：`name author coverUrl intro kind lastChapter wordCount updateTime init tocUrl canReName downloadUrls preUpdateJs`
⇒ `ruleToc`：`chapterList chapterName chapterUrl formatJs isVolume isVip isPay updateTime nextTocUrl preUpdateJs`
⇒ `ruleContent`：`content title subContent nextContentUrl replaceRegex webJs sourceRegex imageStyle imageDecode payAction callBackJs`
⇒ **轻阅两个引擎缺的**：`updateTime` `canReName` `downloadUrls` `preUpdateJs` `formatJs` `isVip` `isPay` `subContent` `replaceRegex` `sourceRegex` `imageDecode` `payAction` `callBackJs` `imageStyle` `src` 变量

### 10.6 本轮落地

| 项 | 状态 |
|---|---|
| 默认引擎 = 自研 Swift 引擎（WebView 降为面板可切的退路） | ✅ build293 |
| URL 选项全集（17 键）+ 站方 `retry` | ✅ legado-engine `043f0b2` |
| `charset` 宿主侧解码（GBK/GB2312/Big5/EUC-JP） | ✅ build293 |
| `@js:` 前缀 ⇒ 整条当 JS（不取尾部） | ✅ build291 |
| `result` 的 JSON 对象 toString 桥 | ✅ build291（老引擎）/ Swift 引擎同步补 |
| `src` 变量（content 的别名） | ⏳ 待补 |
| 其余字段（`replaceRegex` / `formatJs` / `isVip` / `payAction` / `callBackJs` / `updateTime` / `preUpdateJs` …） | ⏳ 待补（可按 legado-E 源码逐条移植） |
