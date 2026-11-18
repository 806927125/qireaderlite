# 引擎整体替换：轻阅老两条引擎 → 用户提供的 `LegadoEngine`

> 2026-11-19 · build296
> 用户原话：「**把你现在的引擎全给我删了，替换成我这个**」
> ⇒ ⇒ 老的两条引擎（**WebView JS 引擎** + **自研 Swift 引擎**）**物理删除**，换成用户上传的 `LegadoEngine.zip`。

---

## 1. 做了什么

| 项 | 之前 | 现在 |
|---|---|---|
| 引擎实现 | ① `QiReaderLite/Resources/engine/*.js`（WKWebView）② `legado-engine`（SPM 远程包，自研 Swift） | **`LegadoEngine/`（仓库内本地 SPM 包）** |
| 引擎选择 | `EngineMode.swift`（`.webView` / `.swiftEngine` 面板切换） | **单一引擎，无开关** |
| 宿主接线 | `RuleSandbox.swift`（1569 行）+ `JSEngineFactory.swift` + `WebViewJSExecutor.swift` + `WebViewJSHost.swift` | `Core/LegadoEngineBackend.swift`（重写）+ `Core/HostKit.swift` / `Core/Toast.swift` / `Core/AppPaths.swift` / `Core/EngineLog.swift` / `Core/EngineLogPanel.swift` |

**删除清单（物理删，不是隐藏）**：

```
QiReaderLite/Resources/engine/       （12 个 .js）
QiReaderLite/Core/EngineMode.swift
QiReaderLite/Core/JSEngineFactory.swift
QiReaderLite/Core/RuleSandbox.swift
QiReaderLite/Engine/WebViewJSExecutor.swift
QiReaderLite/Engine/WebViewJSHost.swift
```

**SPM 依赖**：远程 `legado-engine` ⇒ 本地包 `LegadoEngine/`（`XCLocalSwiftPackageReference "LegadoEngine"`，productName `LegadoEngine`）。

---

## 2. 新引擎的身份与能力

- 来源：用户上传的 `LegadoEngine.zip`（六阅 LegadoR iOS 二进制逆向重建，36 文件 / 522KB）。
- 结构：`AnalyzeRule` / `AnalyzeUrl` / `RuleSplitter` + SwiftSoup + **Kanna 真 XPath**（libxml2）+ 1:1 提取的 Rhino 兼容 JS shim（`JS/Resources/01_core.js`…`05_ttf.js`）+ 自带 `HTTPClient`（用 `HTTPCookieStorage.shared` ⇒ **天然接得上轻阅登录态 cookie**）+ `WebFetcher`。
- 门面：`LegadoEngine.search / exploreKinds / explore / bookInfo / chapters / content`（全部 async throws）。
- 本轮**最小改动**（保持引擎原有 API 不动）：
  - 5 个 op 加**可选注入** `variables: RuleVariables? = nil` ⇒ 宿主能把站方变量灌进去、op 之间延续。
  - 新增 `LegadoEngine/Sources/LegadoEngine/LegadoEngineHost.swift`：宿主侧类型别名入口（`LegadoEngineHost.Source/BookModel/ChapterModel/…`）。
    ⚠️ **为什么需要**：模块名 `LegadoEngine` 与门面 enum `LegadoEngine` 同名 ⇒ `LegadoEngine.BookSource` 会被 enum 遮蔽（`'BookSource' is not a member type of enum 'LegadoEngine.LegadoEngine'`）⇒ 追加别名入口（纯追加，不改引擎 API）。

### 2.1 宿主接线（`Core/LegadoEngineBackend.swift`）

- 5 个 op 全部走新引擎；`login` / `loginProbe` / `filterAction` 用引擎的 `JSBridge` 跑站方 action / loginCheckJs。
  ⚠️ **`source.put('order', …)` 必须真写进去**，否则 `explore` 返回 500（老引擎时代踩过）。
- **变量契约（证据不许自证）**：宿主注入 `RuleVariables`，op 结束后回传 `__sourceVars` / `__sourceVariable` / `__sourceVariableChanged` ⇒ 与种子比较才算「站方真的改了」。
- op 超时预算：bookInfo / toc / content 300s、login 120s、其它 60s。
- `SourceService`：`EngineMode` 分流删除、`invokeWebViewEngine` 删除；login / filterAction / explain / explainToc 改走 `LegadoEngineBackend.shared.invoke`（`Task.detached` 离开主线程）。

### 2.2 平台差异

新引擎的 JS 层只在 Apple 平台（`#if canImport(JavaScriptCore) && !os(Linux)`）⇒ Linux 分支不能引用 `JSBridge` / `JSHost` ⇒ App 的 login / filterAction 分支按平台条件编译。

---

## 3. 门禁

| 门禁 | 内容 | 结果 |
|---|---|---|
| `test/engine-replacement-contract.test.js` | 老引擎痕迹为零 / 新引擎在位 / op dispatch 精确匹配 / 变量契约分分支 / 新引擎自带 20 项测试 | ✅ 47 / 0 |
| `test/mutation-engine-replacement.sh` | 基座绿 + 3 变异红 + 复原绿（**证明门禁有牙齿**） | ✅ 5 / 5 |
| `test/linux-compile-gate.sh` | 链**真新引擎**（本地包 `.build` + Kanna modulemap + `-Xcc -I/usr/include/libxml2`）⇒ typecheck | ✅ 通过 |
| `test/analyze-url-test.swift` | 原生请求层断言改指新引擎的 `AnalyzeUrl`（options / charset / retry） | ✅ |
| swift 原生层 | 330 项 | ✅ 0 失败 |

**随老代码退役的门禁**：`reader-settings` 里「老引擎 JS 桥接」段（删）· `packages-native` / `swift-bookdto`（测的是老引擎的 JS/DTO ⇒ 删）· 旧 harness 系 39 个 `*.test.js` · `engine-lint` / `login-status` / `swift-dto-tolerant` / `op-routing-contract` / `op-shape-consistency` / `toc-jsonpath-rewrite` / `source-variable-contract`。

---

## 4. ⚠️ 未验证项（真机）

- **CI（macOS-26 / Xcode 26.2）编 build296** ⇒ iOS 真机编译 + JSC + Kanna 的真实行为 ⇒ CI 是唯一能验的地方（沙盒 Linux 编不到 JSC）。
- **真机功能清单**：聚合源跑通搜索 / 发现 / 详情 / 目录 / 正文；登录（`source.put` 写变量）；筛选 action（`order_type` 不再 500）；cookie 登录态（`HTTPCookieStorage.shared` 共罐）。

---

## 5. 后续待补（按 legado-E / 新引擎源码逐条）

`webJs` 模式 · `ruleReview`（段评，栖阅独有）· `ruleContent.imageStyle / imageDecode / payAction / callBackJs` · `ruleToc.preUpdateJs` · `ruleBookInfo.downloadUrls / canReName` · `ruleSearch.checkKeyWord`（61 源，但只服务 legado-E 的「书源体检」，轻阅无此功能 ⇒ 暂不做）。

---

## 6. 许可

- 用户上传的 `LegadoEngine` = 逆向重建（个人自用）⇒ **个人自用不触发 GPL 分发义务**。
- 过程中读过 `Luoyacheng/legado-E`（GPL-3.0）作语义参考 ⇒ 若将来对外分发，**必须回头处理 GPL**（转 GPL-3.0 + 附源码，或换成栖阅口径的等价实现）。
