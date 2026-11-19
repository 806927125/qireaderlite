# 交接：发现页 LegadoError 1 的根因与修法（build297）

> 2026-11-19 · 本轮从「用户真机报错」一路查到「引擎换装时丢了一条能力」，再到「用已删的旧引擎当 oracle 做双实现对拍」。
> ⭐ 这条链子**可复用到任何「换引擎后动态规则不跑了」的排查**。

---

## 一、症状

真机（build296 + 适配后的 NovelHub 源）：

```
发现页：未能完成操作。（LegadoEngine.LegadoError 错误 1。）
```

引擎日志：

```
[引擎] 新引擎跑「explore」失败：url 解析失败:
                                       ↑ 冒号后是空的 ⇒ URL 是空串
```

---

## 二、根因（**引擎的能力回退**，不是书源的问题）

| 环节 | 事实 |
|---|---|
| `LegadoEngine.exploreKinds`（`LegadoEngine.swift:35`） | **静态**解析 `source.exploreUrl`，只认 JSON 数组 / `标题::url` 两行式 ⇒ **从不求值 `@js:`** |
| NovelHub 的 `exploreUrl` | 是 **`@js:` 薄壳**（正文在 jsLib 里） |
| ⇒ 静态解析把 `@js:` 那行当成「标题」 | ⇒ **分类 url 为空** |
| `AnalyzeUrl` 对空 url 求值 | ⇒ 抛 `url 解析失败: ` ⇒ **与真机日志逐字吻合**（冒号后为空）⭐ |

### ⭐ 权威规格 = 已删除的旧引擎

git `0b5c481^:QiReaderLite/Resources/engine/engine.js` 的 `exploreKinds`：

```js
if (rule.classify(spec) === rule.T.JS) {   // ← 先求值 @js:
  return rule.runJs(jsCode, scope).then(...)
}
```

⇒ 换装 `LegadoEngine`（commit `0b5c481`，老的两条引擎物理删除）时**丢的就是这条能力**
⇒ 属**能力回退**，⇒ **不只影响 NovelHub**：任何 `exploreUrl` 是 `@js:` 的源在轻阅新引擎上都会中招 ⭐⭐⭐

⇒ **旧引擎在 git 里 = 权威规格** ⇒ 改引擎语义前先 `git show 0b5c481^:QiReaderLite/Resources/engine/engine.js` 抄它 ⭐⭐⭐

---

## 三、修了什么（宿主接线层，**`LegadoEngine/` 零改动**）

> ⚠️ `LegadoEngine/` 是用户在另一窗口自研的引擎 ⇒ **不越界改它的语义**。
> 宿主层已有 `filterAction` / `login` 两条「宿主自己跑站方 JS」的先例 ⇒ 照此办理。

**新增** `QiReaderLite/Core/ExploreKindsNormalizer.swift`
（**只依赖 Foundation** ⇒ 沙盒能编能跑 ⇒ 3 秒反馈，不用等 CI 5 分钟）

**改** `LegadoEngineBackend` 的 `exploreKinds` op：

```
exploreUrl 是 @js:/<js>  ⇒ 用引擎 JSBridge 求值（自动加载站方 jsLib ⇒ 站方 helper 全在）
                         ⇒ 归一化成【分类 + 筛选栏 + 分组】
静态写法               ⇒ 仍走引擎那条路（零回归）
求值失败               ⇒ 如实带 error 回传（不假成功）
```

### 归一化语义（逐条对齐旧引擎）

- `type:"select"` 项 = **筛选栏**（没 url ⇒ 不是分类）
- 对象项 **url 空** = **组标题行**（不输出成分类）
  ⚠️ **判据只能是「url 空不空」，不能看 style**（站方组标题行的 `style.pct` 也可能是 1）⭐⭐⭐
- 站方自带 `group` 字段优先于累积的 group
- 绝对化：协议白名单 + `//host` + **`{{page}}` 占位保护**（不让 URL 引擎把它编码掉）
- ⭐ **`paramKey` 要认两种形态**：
  - 旧引擎 / 大灰狼：`show(infoMap['平台'],'find_source')`
  - **NovelHub：整个 IIFE**，变量名藏在 `c['find_source']=` 里
  ⇒ 只认前者 ⇒ NovelHub 的筛选栏全被判成「不可选」⇒ **切台点了没反应**（静默失效）⭐⭐⭐

---

## 四、门禁（**证明，不是自证**）

| 门禁 | 文件 | 结果 |
|---|---|---|
| **双实现对拍** | `test/explore-kinds-parity.js` | 26 项 ✅ + 6 变异全被抓住 ✅ |
| **发现页端到端** | `test/explore-kinds-live.js` | 7 项 ✅ ⇒ **50 分类 + 7 筛选栏**，paramKey 全对 |
| **workflow YAML** | `test/workflow-yaml-gate.test.js` | 15 项 ✅ + 变异红 ✅ |
| **总门禁** | `test/run-all-gates.sh` | 17 条 + 变异 11 项 + swift 原生层 330 项 **全绿** ✅ |

### ① 双实现对拍（最值钱的一条）

- oracle = **git 里已删的旧引擎**（`0b5c481^`）的 `normalizeKinds` / `filterParamKey` / `absolutize`
  ⇒ 同一批 fixture 喂两套实现 ⇒ **逐字段比** ⇒ 抄歪了立刻红 ⭐⭐⭐
- ⭐ **Swift 侧直接编 App 的真文件**（不是抽取副本 ⇒ **永不漂**）⇒ 独立成 `ExploreKindsNormalizer.swift` 正是为此
- ⇒ **当场抓出 3 个我自己写歪的真 bug**：
  1. `{{page}}` 占位**少一个 `}`** ⇒ 站方占位符展开废了
  2. 纯文本形态**该切对象却切了字符串** ⇒ 组标题被剥了装饰符 ⇒ 与旧引擎不一致
  3. `paramKey` **双重语义**（oracle 外面又算了一遍）⇒ 假象

⇒ ⭐⭐⭐ **「照抄旧引擎」最危险的失败模式 = 自以为抄对了** ⇒ 唯一能证伪 = 双实现对拍 ⭐⭐⭐

### ② 端到端（静态对拍不够 ⇒ 必须真跑）

跑**产物里的真实 jsLib（1.1MB）+ 真实 exploreUrl + 真实站方接口** ⇒ **50 分类 + 7 筛选栏**，
每项 paramKey 都抠对（find_source / kind / gender / status / sort / line / mode），
分类 URL 里的 `{{page}}` **占位保住了** ⇒ 发现页翻页不会静默失效 ⭐⭐⭐

⚠️ **诚实边界**：Node ≠ JSC（Rhino shim 不生效）；`java.ajax` 在 Node 异步、新引擎同步（`requestSync`）
⇒ 脚本用**同步子进程**对齐引擎语义 ⇒ 「语义」由对拍证、「能不能真跑出分类」由端到端证 ⇒ **两层合起来才完整** ⭐⭐⭐
⚠️ 站方 `nhAuth()` 是**登录门**（`source.get("nhAuthed")`==`NH_PWD_HASH`）⇒ 未登录时 exploreUrl **主动降级返空**
⇒ 垫片必须注入登录态（hash 从**产物自己的 jsLib** 里读，不写死）⭐⭐⭐

### ③ CI 坑：workflow YAML 的**裸 `@` 是保留指示符**

step name 里写 `@js:` ⇒ **整个 workflow 解析失败** ⇒ 症状 = **CI 立刻失败、且一个 job 都没有**（`jobs: []`）
⇒ 报错极不直观 ⇒ 容易误判成编译问题 ⇒ **白查一轮 CI** ⇒ 正解：本地 `js-yaml` parse 一遍（3 秒）⭐⭐⭐

---

## 五、书源适配（`NovelHub聚合小说-轻阅新引擎适配.json`）

27 个字段里**只改 4 个**，其余 23 个（searchUrl / exploreUrl / 各 rule / header）**一字未动**：

| 改动 | 原因 |
|---|---|
| `loginUi` 静态平铺（284 条目 / 184 按钮） | 轻阅登录面板直接读 loginUi 原始 JSON、**不求值 `@js:`** |
| 切台同步写 `find_source`/`find_tab` | 轻阅发现页缓存键 = `bookSourceUrl\|find_source\|find_tab` ⇒ 只改 `NH_D.src` 会命中 30 分钟缓存 |
| `base64Decode` / `hexDecodeToString` 纯 JS 兜底 | 新引擎里这两个 API 不存在，`java` 是 Proxy ⇒ 不抛异常、返 null ⇒ `String(null)="null"` 静默污染 |
| 视频/浏览器链接落进正文 | 新引擎的 `startBrowser*`/`openVideoPlayer` 是 no-op |

构建**逐字节可复现**（重跑字节恒定，已验）⇒ `work/nh/patch_source.py` 是唯一事实来源。

---

## 六、遗留（如实记录，不阻塞）

- ⚠️ **引擎 revision 未注入 UI**：`EngineRevision.generated.swift` 没被引用 ⇒ 面板显示的引擎号是手写的
  （CI 明明把 40 位 sha 注入了文件，但没人用它）⇒ 下轮修
- ⚠️ **端到端门禁在 CI 上是显式 SKIP**（CI checkout 里没有书源产物）⇒ 真跑在本地/真机做
- ⚠️ **Node ≠ JSC**：见上面「诚实边界」

---

## 七、提交历史

| commit | 内容 |
|---|---|
| `97b0a29` | 核心修复：宿主层补 `@js:` exploreUrl 求值 + 归一化 + 双实现对拍门禁 |
| `318d9f4` | 补 NovelHub 的 paramKey 形态 + 发现页端到端门禁 |
| `dbefc2b` | 修 CI run 468（YAML 裸 `@` 保留指示符）+ 加本地 YAML 门禁 |

CI：run 467 / 468（解析失败）/ **run 469 绿** ⇒ build297（`CFBundleVersion = 297`）。
