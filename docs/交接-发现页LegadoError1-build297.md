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


---

# 追加（build298）：第二层根因 = **站方变量两格不通**

> 用户装 build297 后反馈：发现页从「LegadoError 错误 1」变成「**只解析出 0 个分类**」
> ⇒ 上一步的修复**生效了**（`@js:` 的 exploreUrl 真跑了）⇒ 但站方 JS **主动交白卷** ⇒ 又一层根因 ⭐⭐⭐

## 根因

| 方向 | 引擎读/写哪 | App 灌/收哪 | 结果 |
|---|---|---|---|
| **读** | `srcGet` → **`BookSource.variable`** 那一格 | `srcDict["__variable"]` → `session.variables`（**另一格**） | ❌ 站方 JS 读 `source.get("nhAuthed")` **恒空** |
| **写** | `srcPut` → `BookSource.variable`（**JSBridge 内的副本**） | 回传 `session.variables`（**另一格**） | ❌ 站方 `source.put(...)` **写不回来** |

⇒ 站方 `exploreUrl` 第一行 `if (!nhAuth()) { return ""; }` ⇒ `nhAuth()` 恒 false
⇒ **主动交白卷**（不是崩溃 ⇒ 最难查的一类）⇒ 0 个分类 ⭐⭐⭐

⚠️ **隐蔽点**：App 的 `BookSource` 模型**根本没有 `variable` 字段**、`srcDict` 也**从不塞 `"variable"`**
⇒ 引擎那一格**永远是空的** ⇒ 从来没人发现（大部分源不读变量）⭐⭐⭐

⚠️ **另一半**：通用 op 的收尾回传 `__sourceVariable` 原来回传的是**书籍变量**那一格
⇒ 宿主落盘时把书籍变量的 map 写进了**站方变量槽** ⇒ **两格互相污染** ⭐⭐⭐

## 修法（宿主层，**零引擎改动**）

1. **读**：把 App 的站方变量灌进 `engineSource.variable` ⇒ 站方 JS 读得到
2. **写**：站方 JS 写的是 JSBridge 内的副本（`JSBridge.source` 模块内可见 ⇒ 宿主读不到）
   ⇒ **`bridge.eval("source.getVariable()")`** 把副本里的值读出来（纯 JS ⇒ 不碰引擎）
3. **回传**：`__sourceVars` = 书籍变量；`__sourceVariable` = **站方那一格**；两格不许混
4. **种子**：站方变量要有自己的种子（= 灌进去的值）⇒ 判「改没改」不是自证
5. ⚠️ **闭包传参**：`LegadoEngineHost.Bridge` 别名只在 Apple 平台存在 ⇒ Linux 沙盒编不过 ⇒ 用闭包传

## ⭐⭐⭐ 本轮最有价值的门禁教训

**端到端脚本若是「假接线」，它会掩盖真机故障** ⭐⭐⭐

- 早先的端到端脚本「手工往 `source.get` 的 map 里塞 `nhAuthed`」⇒ **源与真机不同构**
  ⇒ 真机 0 分类它照样绿 ⇒ **门禁抓不到故障** ⭐⭐⭐
- ⇒ 正解：**端到端必须模拟【宿主的真实接线】**（整格灌进 `variable` ⇒ `source.get` 从 `variable` 读）
- ⚠️⚠️ **且两格内容必须独立**（书籍变量那格**不许含** `nhAuthed`）
  ⇒ 否则「读错的格」照样读得到 ⇒ **变异照样绿** ⇒ 门禁没牙齿 ⭐⭐⭐
- ⇒ 固化变异：「读错的格」⇒ **精确复现真机症状「0 个分类」** ⇒ 端到端 8/8 ✅

## 新增门禁

| 门禁 | 文件 | 结果 |
|---|---|---|
| **站方变量通道** | `test/station-var-channel.test.js` | 20 项 ✅ + 4 变异全抓住 ✅ |
| 端到端（真实接线 + 变异） | `test/explore-kinds-live.js` | 8 项 ✅ |

build 号 298（commit `d75b27e`）。


---

# 追加（build299）：第三层根因 = **引擎只有一格 map，而站方两格混用**

> build298 真机：仍是「只解析出 0 个分类」⇒ build297 的方向对，但**灌错了形态**。

## 根因

引擎只有**一格** `BookSource.variable`（一个 JSON map），而站方**两格混用**：

| 站方 API | 语义 | 落点 |
|---|---|---|
| `source.get("nhAuthed")` / `source.put(k,v)` | **map 的某一项** | `variable` 这一格的某项 |
| `source.getVariable()` / `source.setVariable(str)` | **整份 map 的 JSON 串**（站方 `JSON.parse` 它拿 NH_D） | `variable` 这一格的**整份** |

⇒ build298 把【站方变量整串】灌进 `variable` ⇒ `source.get("nhAuthed")` 去 map 里找 ⇒ **找不到** ⇒ 恒空
⇒ `nhAuth()` 恒 false ⇒ 站方 `exploreUrl` **主动交白卷** ⇒ **0 个分类**
⇒ **症状与「没修」一模一样**（这就是「探针自证」缺失的代价）⭐⭐⭐

## 修法（宿主层，零引擎改动）

- ⭐⭐⭐ **两格合并成一份 map** 再灌进 `engineSource.variable`：
  - 书籍变量 map 的项（`nhAuthed` / `nhPlatSwitch` / `token` …）**优先** ⇒ 覆盖 `source.get/put` 的项
  - 站方变量整串解析后的项（`src` / `gender` / …）并进去 ⇒ `source.getVariable()` 解析出来就有 NH_D
- ⭐⭐⭐ **Session 缓存缺陷**：`Session` 按源缓存 ⇒ 第一次 op 灌的变量会被一直沿用
  ⇒ 用户后来在登录面板**解锁**（写了 `nhAuthed`）⇒ 缓存里还是旧值 ⇒ **仍然交白卷**
  ⇒ 正解：**每个 op 都用最新的 payload 重新合并灌**（`refreshStationVariable`）

## ⭐⭐⭐ 用户要做的动作（App 修不了的部分）

**站方聚合源自带「整源密码门禁」**：`exploreUrl` 第一行就是 `if (!nhAuth()) { return ""; }`
⇒ **未解锁 ⇒ 站方主动交白卷（不报错）** ⇒ 「0 个分类」⭐⭐⭐

⇒ **操作路径**：书源登录 → 「整源解锁密码」输入框填密码 → 点「🔓 解锁整个源」
（站方 `unlockAll()` 读登录表单值 → `md5` 比对 → `source.put("nhAuthed", hash)`）

⚠️ **出厂密码只有源作者有**（源里只有 `NH_PWD_HASH` = md5，没有明文）
⚠️ **不自动解锁**是**有意的**：站方注释写明这个门禁的价值是「源不外传」⇒ 自动填 = 绕过它的目的 ⭐⭐⭐

## 诊断已加

「0 个分类」的文案现在**点名【站方的整源密码门禁没解锁】**（旧文案「分类接口没通」是误导）
⇒ 判据：站方把解锁态存在**书源变量**的 `nhAuthed` 项 ⇒ 宿主查自己那份就知道是不是没解锁 ⭐⭐⭐

## 门禁

| 门禁 | 结果 |
|---|---|
| `test/station-var-channel.test.js` | 21 项 ✅ + 5 变异全抓住（新增「不再合并两格」⇒ 精确复现 build298 现场）|
| `test/explore-kinds-live.js` | 8 项 ✅ + 变异「读错的格」⇒ 精确复现真机症状「0 个分类」|
| 全量 | 18 条 + swift 原生层 330 项 全绿 ✅ |

build 号 299（commit `c334c74`）。


---

# 追加（build300）：第四层根因 = **「解锁按钮读不到密码」**（真机诊断实证）

> 用户跑了「测书源」，诊断时间线给了**决定性证据**：
>
> ```
> [变量] 槽={"fqcommunity":"on","nhPlatState":"src=全部 kind= 分类 形态=map jsLib=1145487 字 取过默认表=true 是map=true}
> [变量] 迁移=没清（形态=map 站方写过=false 是map=true）
> [引擎] 新引擎的「exploreKinds」结果不可信（只解析出 0 个分类（站方正常是几十上百个 ⇒ 说明站方的分类没出来））
> ```
>
> ⇒ ① 站方变量槽里**没有 `nhAuthed`** ⇒ **解锁从未成功**（不是「没解锁」，是「解锁按钮按了没用」）⭐⭐⭐
> ⇒ ② 文案是**旧文案**（没有 build299 的 hint）⇒ **装的不是 build299** ⇒ 顺手补 build 号显示 ⭐⭐⭐

## 第四层根因

| 环节 | 事实 |
|---|---|
| 站方读密码 | `nhAuthUiMap()` ⇒ **`source.getLoginInfoMap()`** ⭐⭐⭐ |
| 引擎的 `loginInfoGet` | ⇒ **`BookSource.variable["loginInfo"]`** ⭐⭐⭐ |
| 轻阅的 login op | **只把表单值放进 `result`** ⇒ 站方读到**空 map** ⭐⭐⭐ |

⇒ 点「🔓 解锁整个源」必然提示「请在下面输入框里填密码」⇒ **永远解锁不了** ⇒ 永远交白卷 ⭐⭐⭐

## 修法

- ⭐⭐⭐ **login op 执行前，把「已存登录信息 + 本次表单值」合并写进引擎那一格的 `loginInfo` 项**
  - 合并规则：已存的做底 + 本次表单值覆盖（**空值不覆盖**）⇒ 与 Legado 语义一致
- ⭐⭐⭐ **执行与回传必须用【同一个 bridge】**
  - ⚠️ 我第一版换成了 `bridge2` ⇒ 回传读的是**另一份副本**
    ⇒ 站方 `source.put(...)`（含解锁态 `nhAuthed`）**读不回来**
    ⇒ 被 `engine-replacement-contract` 门禁**当场抓住** ⭐⭐⭐

## 顺带：测书源面板显示 build 号

- ⚠️⚠️ **为什么必须放在这个面板**（不是只放引擎日志面板）：
  用户反馈故障**只看这个面板** ⇒ 看不到 build 号 ⇒ 我按 build298 分析、真机却是 build297 ⇒ **整轮排查白做** ⭐⭐⭐
- ⇒ 这个面板是「用户报障的第一现场」⇒ build 号必须在这里 ⭐⭐⭐

## 门禁

| 门禁 | 结果 |
|---|---|
| `test/station-var-channel.test.js` | 26 项 + 6 变异全抓住（新增「loginInfo 不并进引擎那一格」）|
| `test/explore-kinds-live.js` | 14 项（新增**解锁链**整段：表单值 → loginInfo 项 → 站方读到密码 → 写 nhAuthed → nhAuth() 放行）|
| `test/engine-replacement-contract.test.js` | 切片从【固定长度】改成【按结构】（固定长度 ⇒ 分支代码一多就把回传挤出窗口 ⇒ **假红**；变异自证没变弱）|
| 全量 | 18 条 + swift 原生层 330 项 全绿 ✅ |

build 号 300（commit `9d595ec`）。

## ⚠️ 给用户的动作（两件）

1. **装 build300**（测书源面板现在会显示 `版本 (build 300)` ⇒ 一眼确认）
2. **解锁**：书源登录 → 「整源解锁密码」填密码 → 点「🔓 解锁整个源」→ 回发现页
   - ⚠️ 出厂密码只有源作者有（源里只有 `NH_PWD_HASH` = md5，没有明文）
   - ⚠️ **不自动解锁**是有意的：站方注释写明这个门禁的价值是「源不外传」⇒ 自动填 = 绕过它 ⭐⭐⭐


---

# 追加（build300 终版）：第四层修完 + **沙盒盲区根治**

## 第四层（build300 已修）

**根因**：站方读密码 = `nhAuthUiMap()` ⇒ `source.getLoginInfoMap()`
⇒ 引擎的 `loginInfoGet` ⇒ **`BookSource.variable["loginInfo"]`**
⇒ 而轻阅的 login op **只把表单值放进 `result`** ⇒ 站方读到**空 map**
⇒ 点「🔓 解锁整个源」必然提示「请在下面输入框里填密码」⇒ **永远解锁不了** ⭐⭐⭐

**修法**：
- ⭐⭐⭐ login op 执行前，把「已存登录信息 + 本次表单值」**合并写进引擎那一格的 `loginInfo` 项**
- ⭐⭐⭐ **执行与回传必须用【同一个 bridge】**（我第一版换了 `bridge2` ⇒ 回传读的是另一份副本
  ⇒ 站方 `source.put`（含 nhAuthed）**读不回来** ⇒ 被 `engine-replacement-contract` 门禁当场抓住）⭐⭐⭐
- ⭐⭐⭐ **回传时剥掉 `loginInfo` 项**（它含**明文密码** ⇒ 混进站方变量槽 ⇒ 明文躺盘
  ⇒ 站方自己的 `nhAuthWipe()` 也是为了这个）⭐⭐⭐

## ⭐⭐⭐ 沙盒盲区的根治（这次最大的认识）

**CI build300 连红两轮，两轮都是 Apple-only 块里的类型错**：
- ① `type 'Self' has no member 'stripLoginInfo'`（方法在嵌套 `Session`，调用点却写 `Self.`）
- ② `value of optional type 'String?' must be unwrapped`（`engineSource.variable` 是 optional）

⚠️⚠️⚠️ **根因 = 那段代码在 `#if canImport(JavaScriptCore) && !os(Linux)` 里面**
⇒ **Linux 编译门禁根本编不到** ⇒ 沙盒全绿、CI 连红 ⇒ **每轮白等 5 分钟** ⭐⭐⭐

⇒ ⭐⭐⭐ **根治不是加断言，是【改结构】**：
把**纯 Swift 的数据处理逻辑**挪到 `#if` **外面**
（`Session.engineSourceWithLoginInfo(formValues:)` ⇒ 只把「跑 JS」留在 `#if` 里）
⇒ **Linux 门禁编得到** ⇒ 类型错 3 秒暴露 ⭐⭐⭐
⇒ 变异自证：去掉 `?? ""` ⇒ **沙盒当场报出与 CI 一模一样的错误** ✅

⇒ **教训（升级版）**：**「沙盒编不到」的那部分代码，等于没有门禁**
⇒ 要么把逻辑挪到编得到的地方，要么补静态门禁（`test/apple-only-typecheck.test.js`）⭐⭐⭐

## 门禁（最终）

| 门禁 | 结果 |
|---|---|
| `test/station-var-channel.test.js` | 31 项 + 7 变异全抓住 |
| `test/apple-only-typecheck.test.js` | 10 项（**新增**：Apple-only 块的 `Self.<方法>` 作用域归属）+ 变异自证 |
| `test/explore-kinds-live.js` | 14 项（含**解锁链**整段）|
| `test/engine-replacement-contract.test.js` | 切片从【固定长度】改成【按结构】（假红修复）|
| `test/mutation-engine-replacement.sh` | 锚点跟着实现走（否则变异无效 ⇒ 没牙齿）|
| 全量 | 19 条 + 变异 11 项 + swift 原生层 330 项 全绿 ✅ |

## ⚠️ 给用户的动作（两件，顺序不能反）

1. **装 build300**（测书源面板现在会显示 `版本 (build 300)` ⇒ 一眼确认装的是哪版）⭐⭐⭐
2. **解锁**：书源登录 → 「整源解锁密码」填密码 → 点「🔓 解锁整个源」→ 回发现页
   - ⚠️ 出厂密码只有源作者有（源里只有 `NH_PWD_HASH` = md5，**没有明文**）
   - ⚠️ **不自动解锁**是有意的：站方注释写明这个门禁的价值是「源不外传」⇒ 自动填 = 绕过它 ⭐⭐⭐

build 号 300（commit `14e2b52`）。
