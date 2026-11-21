# NovelHub 聚合小说 · 书源设计文档

> 版本：v11z（2026-11-19 产物） · 定位：**多平台聚合型书源**（一个源聚合 26 个站点）
> 配套宿主：轻阅 Lite（柴阅引擎） · 产物：`NovelHub聚合小说-轻阅新引擎适配.json`

---

## 0. 一句话定位

**把 26 个小说/漫画站点聚合成一个书源**，用统一的「平台下拉 + 分类 + 筛选栏」呈现，
并在书源侧自带**登录/解锁/短评/热评/降级/自检**能力 —— 使得它在**任何 Legado 系宿主**里都能用。

---

## 1. 宿主环境假设

书源跑在 **Legado 语义的宿主**里，依赖以下能力（缺失时按 §7 降级，绝不抛 `ReferenceError`）：

| 能力 | 用途 |
|---|---|
| `source.get/put(k,v)` | 书源变量 map（平台切换标记、各平台令牌、CK…）|
| `source.getVariable()/setVariable(str)` | **站方变量整串**（`NH_D`：平台/频道/排序/线路…）|
| `source.getLoginInfoMap()/putLoginInfo()` | 登录表单数据 |
| `java.ajax/ajaxAll/post/get` | 网络 |
| `java.toast/longToast/log/copyText` | 提示与诊断 |
| `java.startBrowserAwait/showBrowser/openVideoPlayer` | 浏览器/视频（登录扫码）|
| `cookie.getCookie/getKey/setCookie` | Cookie |
| `cache.get/put/putMemory/getFromMemory` | 缓存 |
| `infoMap` | **全局变量**：筛选栏当前选中值 |

⚠️ **两个致命约束**（决定了下文的架构）：
1. **单条规则上限 ~8192 字符** ⇒ 大段 JS 放不进 `exploreUrl`/`searchUrl`/各 `rule*` ⇒ ⇒ **§2 slim 化**
2. **jsLib 是「间接 eval」加载** ⇒ 顶层符号进**全局作用域** ⇒ ⇒ **§3.3 命名必须带 `nh` 前缀**

---

## 2. 总体架构：slim 薄壳 + jsLib 主体

```
书源 JSON
├── jsLib（1.1 MB）──────────── 全部逻辑主体
│   ├── var nhSlim_nh_<rule>_BODY = "…"   ← 每条规则的正文字面量（8 条）
│   ├── function nhSlim_nh_<rule>(...)     ← 薄壳包装：把正文搬进 jsLib
│   ├── function nhPlatCharsFor(type)       ← 平台表（唯一事实来源）
│   ├── function nhAuth/nhPwdHash/unlockAll ← 口令门禁
│   ├── function nhReview*                  ← 短评/热评
│   └── function nhNhHostCap()             ← 宿主能力探测
│
├── exploreUrl  = "@js: … nhSlim_nh_exploreUrl.call(this, …)"   ← 薄壳
├── searchUrl   = "@js: … nhSlim_nh_searchUrl.call(this, …)"
├── loginUrl    = "(0, eval)(nhSlim_nh_loginUrl_BODY)"        ← 间接 eval
└── ruleBookInfo / ruleToc / ruleContent / ruleExplore         ← 各自薄壳
```

### 2.1 为什么 slim 化

站方把每条规则的正文都放在规则字段里，**番茄一类源的 `exploreUrl` 就有 51 KB、整源 113 KB** ⇒ 撞上宿主的单规则上限。
⇒ **解法**：正文搬进 `jsLib` 的字面体，规则字段只留一行薄壳：

```js
// 规则字段（薄壳）
@js:
var __nhSlimOut = nhSlim_nh_exploreUrl.call(this,
  (typeof result   !== 'undefined') ? result   : '',
  (typeof book     !== 'undefined') ? book     : {},
  (typeof baseUrl  !== 'undefined') ? baseUrl  : '',
  (typeof page     !== 'undefined') ? page     : 1,
  (typeof key      !== 'undefined') ? key      : '');
return __nhSlimOut;
```

⚠️ 薄壳里**所有宿主变量都要 `typeof` 兜底**（宿主不保证给全）⇒ 缺了也不炸。
⚠️ 薄壳**必须有 `return`**（规则语义：末行表达式即返回值 ⇒ `return` 显式更安全）。

### 2.2 字面体的编码

`jsLib` 里的字面体是 **JS 字符串字面量**（不是 JSON）⇒ 必须按 JS 规则转义（`\n` `\"` `\\`）⇒
⇒ 构建器 `patch_source.py` 负责 `dec_js_literal` / `enc_js_literal` 双向转换。

### 2.3 间接 eval 与全局作用域

`loginUrl` 用 **`(0, eval)(nhSlim_nh_loginUrl_BODY)`** ⇒ 目的是让 `jsLib` 里的**函数声明落进全局作用域**（间接 eval 不继承局部作用域）⇒
登录菜单里才能直接调 `nhUaaLogin()` 之类。

⚠️⭐⭐⭐ **由此产生一条铁律**：

> **jsLib 顶层符号一律带 `nh`/`nhNh`/`_NH_` 前缀** ——
> 因为顶层符号会**污染全局作用域**，会**撞名别的书源**。

（书源里已经吃过这个亏：注释写着「⚠ 名字带 nhNh 前缀：站方 jsLib 是【间接 eval】⇒ 顶层符号进全局作用域 ⇒ 撞名会污染别的书源」。）

### 2.4 分类数组的参数化展开（省体积）

站方原本每个分类写一条完整 URL（番茄 302 条 = 51 KB）⇒ 改成**前缀 + 后缀 + 差异段**：

```js
function _nhRows(pfx, sfx, rows, sty) {
  var out = [];
  for (var i = 0; i < rows.length; i++) {
    var e = { "title": rows[i][0], "url": pfx + rows[i][1] + sfx };
    if (sty !== null) { e.style = sty; }
    out.push(e);
  }
  return out;
}
var NH_FQ = _nhRows("http://…/get_discover?source=番茄&tab=小说&", "&page={{page}}", [
  ["🏆 男频·推荐榜", "bdtype=推荐榜&gender=1&is_ranking=1"],
  …
]);
```
⇒ **拼回结果与原来逐字节相同**（由 `tools/verify_explore.py` 逐条比对钉死）⭐⭐⭐

---

## 3. 变量体系：三套槽，**不许混** ⭐⭐⭐

这是全书源最容易出事的地方。三套槽各有职责：

| 槽 | API | 存什么 | 谁写 | 谁读 |
|---|---|---|---|---|
| **① 站方变量整串** | `source.getVariable()` / `setVariable(JSON)` | `NH_D`：`src`/`gender`/`status`/`sort`/`line`/`kind`/`mode`/`fqWord`/`fqStatus`/`fqSort`/`find_source`/`find_tab` | 筛选栏 action、菜单切台 | `exploreUrl` 开头、搜索/目录/正文规则的出口 |
| **② 书源变量 map** | `source.put(k,v)` / `get(k)` | `nhPlatSwitch`/`nhPlatLog`/`nhPlatSync`/`nhHostCaps`/`nhSafeMode`/`nhImgRef`/`nhUaa*`/`nhCyj*`/`nhMy*`/`mgck`/`nhDlhHost`… | 登录/切台/诊断 | 对应的功能分支 |
| **③ 登录信息** | `source.getLoginInfoMap()` / `putLoginInfo` | 账号/密码/令牌/JWT/CK | 登录面板 | 登录与请求流程 |

### 3.1 为什么必须分三套

⚠️ **书源自己踩过的坑（源码原话）**：

> 「⚠ 状态一律 `source.put()`（书源变量 map），**不用 `setVariable`** —— `setVariable` 那个槽位是 NovelHub 的 `NH_D`（平台/频道/排序/线路），两边共用会互相覆盖（症状：**登录一次发现页筛选被重置**）。」

⇒ **规则**：登录态/令牌/CK ⇒ 一律 `source.put`；平台/频道/排序/线路 ⇒ 一律 `setVariable`。

### 3.2 `NH_D` 的键与默认值

```js
var NH_D = {"src":"全部","gender":"全部","status":"不限","sort":"最热","line":"自动"};
try {
  var _raw = String(source.getVariable() || "").trim();
  if (_raw !== "") { var _o = JSON.parse(_raw); if (_o && typeof _o === "object") { NH_D = _o; } }
} catch (e) { }
if (!NH_D.src)   { NH_D.src = "全部"; }
if (!NH_D.gender){ NH_D.gender = "全部"; }
if (!NH_D.status){ NH_D.status = "不限"; }
if (!NH_D.sort)  { NH_D.sort = "最热"; }
if (!NH_D.line)  { NH_D.line = "自动"; }
if (!NH_D.kind)  { NH_D.kind = "🌐全部"; }      // 📖小说 / 📕漫画
if (!NH_D.mode)  { NH_D.mode = "小说"; }        // 小说 / 听书
if (!NH_D.fqWord) / fqStatus / fqSort            // 番茄专属三档
```

⚠️ **读法固定**：一律 `source.getVariable()` → `JSON.parse` → **逐字段兜底** ⇒ 旧数据/缺字段都不会炸。

### 3.3 `infoMap`：筛选栏的「当前选中值」

`infoMap` 是**宿主注入的全局变量**，语义 =「筛选栏当前各选项的值」。

⇒ 站方 action 的统一形态（见 §4.3）：`infoMap['<标题>']` 取用户选的值。
⇒ ⚠️ **宿主若不注入 `infoMap`，筛选必然回落到默认值** ⇒ 这是「筛选没用」的第一大来源。

---

## 4. 发现页契约

### 4.1 `exploreUrl` 返回什么

一段 **JSON 数组字符串**，元素两类：

```jsonc
// 分类（可点 ⇒ 请求 url）
{ "title": "👨完结榜·全部", "url": "http://…/discovedata?type=4&page={{page}}", "style": {...} }

// 筛选栏（点不 ⇒ 改变量）
{ "title": "平台", "type": "select", "chars": ["书旗","番茄",…], "default": "书旗",
  "action": "(function(){ … })()", "style": {...} }
```

⚠️ **铁律（源码原话）**：
> 「不能有顶层 `return`；末行表达式即返回值；只返回 JSON 数组字符串。」

### 4.2 平台表 = 唯一事实来源 ⭐⭐⭐

```js
function nhPlatCharsFor(type) {
  var _all = ["书旗","番茄","QQ阅读","全本","成人","漫画","情幻文学","木瓜漫画","七猫","八叉",
              "爱丽丝","肉文屋","禁漫天堂","速读谷","开心看漫画","龙天空","就爱文学","热辣漫画",
              "漫客栈","UAA","灵猫小说","次元姬","起点聚合","西瓜书屋","91Hub","18色漫"];
  try {
    if (String(source.get("nhSafeMode") || "") === "1") {
      var _nhh = ["全本","成人","漫画",…];      // 18 禁默认清单
      _all = _all.filter(function (k) { return _nhh.indexOf(k) < 0 || nhSafeAllowed(k); });
    }
  } catch (e) { }
  …
}
```

⚠️⭐⭐⭐ **源码里记着一个血淋淋的教训**：
> 「平台下拉选项的唯一事实来源**就在这里**（2026-10-14 修）：原来想复用 `exploreUrl` 的 `_NH_PLAT`，但 **`exploreUrl` 是 IIFE，jsLib 函数根本读不到它** —— `typeof _NH_PLAT` 永远 `undefined` ⇒ 永远走下面这份表 ⇒ **18 禁过滤做在 `_NH_PLAT` 上 = 做了个寂寞**。」

⇒ **规则**：下拉选项只有一份表（在 jsLib 里），`exploreUrl` 里的 `_NH_PLAT` 是**副本**，18 禁过滤**必须**在 `nhPlatCharsFor` 里做。

### 4.3 筛选栏 action 契约 ⭐⭐⭐

统一形态（**大灰狼聚合已验证的契约**）：

```js
(function(){
  var c = {};
  try { c = JSON.parse(source.getVariable() || '{}'); } catch (e) {}
  var v = infoMap['平台'];                       // ① 取用户选的值
  var m = {"番茄":"番茄","七猫":"七猫", …};        // ② 值→值的映射（可省）
  var nv = (v!==null && v!==undefined && m[v]!==undefined) ? m[v] : '默认值';
  c['src'] = nv;                                 // ③ 写进站方变量整串
  try { source.setVariable(JSON.stringify(c)); } catch (e) {}
  try { infoMap.put('平台', nv); } catch (e) {}   // ④ 回写下拉框（不回写 = 下拉框不重绘）
  try { java.refreshExplore(); } catch (e) {}     // ⑤ 刷新发现页
})()
```

⚠️ **五个动作缺一不可**：
1. 读 `infoMap['<标题>']`（用户选的值）
2. 值映射（`m[v]`），取不到 ⇒ 回落默认值
3. `source.setVariable(JSON.stringify(c))`（**站方变量整串**）
4. `infoMap.put(标题, nv)`（**回写下拉框**）
5. `java.refreshExplore()`（刷新）

⚠️ **站方变量整串的键名 ≠ 筛选标题**：例如「平台」写的是 `src`，而「📚类型」写的是 `kind`，「频道」写 `gender`。
⇒ **宿主不能猜键名** ⇒ 正确做法是**让站方 action 自己写**（它知道该写哪个键）⭐⭐⭐

### 4.4 下拉框自愈（`nhPlatSwitch` 机制）

⚠️ 症状：登录菜单切台后，发现页下拉框还停在旧平台 ⇒ 「切不过去，要下拉刷新才生效」。

机制：
- 登录菜单切台时写**一次性标记** `source.put('nhPlatSwitch', '')`（非空 ⇒ 生效）
- `exploreUrl` 求值时：**有标记** ⇒ 以**源变量为准**（不回退），并把 `infoMap['平台']` **同步成源变量的值**；等 `infoMap` 跟上了 ⇒ **清标记**，把控制权交回下拉框
- **无标记** ⇒ 「下拉框说了算」：`infoMap['平台']` 合法且与 `NH_D.src` 不同 ⇒ 覆盖 `NH_D.src`

⚠️ 源码原话：
> 「标记**不再一次性消费**。原写法『见到标记就清掉』⇒ 只保护**第一次** exploreUrl；而发现页一次交互会跑**多次** exploreUrl（进入 + 刷新 + 回列表）⇒ 第二次就被自愈块按『下拉框里的旧值』回退 ⇒ 菜单切台看起来完全没反应。」

---

## 5. 登录与解锁

### 5.1 登录菜单（`loginUi`）

- 结构：**分组菜单**（`main` + 16 个子菜单：uaa / dhl / cyj / my / kx / mg / jm / al …）
- 每个条目：`{name, type: "text"|"button"|…, action: "<JS>"}`
- 状态行 `📌 当前状态（点击复制）` 只保留一份

⚠️ **轻阅适配（P1）**：轻阅的登录面板**直接读 `loginUi` 的原始 JSON，不求值 `@js:`** ⇒
⇒ **把分组菜单静态平铺**（加 `━━━━━━ 分组名 ━━━━━━` 的分隔行，条目拉平）⇒ 轻阅就能显示按钮 ⭐⭐⭐

### 5.2 整源口令门禁（`nhAuth`）

```js
var NH_PWD_HASH = "0c220581ebbb1121d9c2b33466045387";   // 默认口令的 md5
function nhPwdHash() {
  try { var h = String(source.get("nhPwdHash") || ""); return (h === "") ? NH_PWD_HASH : h; }
  catch (e) { return NH_PWD_HASH; }
}
function nhAuth() { …比较 source.get("nhAuthed") 与 nhPwdHash()… }
```

`exploreUrl` / `searchUrl` 开头统一是：
```js
if (!nhAuth()) { return ""; }        // 未解锁 ⇒ 主动交白卷（不报错）
```

⇒ **症状特征**：解锁前发现页**空空如也但不报错**；解锁后（`source.put('nhAuthed', md5(口令))`）立刻出分类。

### 5.3 各平台登录

| 平台 | 机制 | 关键变量 |
|---|---|---|
| **UAA** | 共享令牌 / 账号密码（`/console/login`）/ 令牌续期 / 设备ID 重置 | `nhUaaToken`、`nhUaaAid`、`nhUaaAccount`、`nhUaaPageSize`、`nhUaaHostIndex`、`nhUaaTocEpoch` |
| **次元姬** | 浏览器登录 → 读 Cookie `CYJapiToken` → 写 JWT | `nhCyjJwt`、`nhCyjType`、`nhCyjGender`、`nhCyjCats`、`nhCyjApiHost` |
| **起点聚合** | 邮箱密码 → `/legado/login` | `nhMyToken`、`nhMyPlat`、`nhMyTab`、`nhMyMenu` |
| **漫客栈** | 账号密码 / 扫码（读 `LOGINSIGN` Cookie）| `mgck` |
| **爱丽丝** | 共享服要 UAA 令牌 / 官网 HTML 免令牌 | — |
| **七猫 / 番茄 / 书旗 …** | 共享服或官方接口 | 线路/host 相关 |

⚠️ **令牌类状态一律 `source.put`**（§3.1）⇒ 不污染 `NH_D`。

---

## 6. 平台适配表（26 个）

| 平台 | 入口 | 坑（源码记录）|
|---|---|---|
| 书旗 | 大灰狼 `/discovedata?source=书旗&tab=小说` | 必须带 `source_type=男频|女频`，漏了只回 2 个占位项 |
| 番茄 | 大灰狼 `/get_discover?source=番茄&tab=小说` | 官方 `api/library/book_list` 全组合返 0 本；`gender` 是 URL 参数，实测生效 |
| QQ阅读 | 大灰狼 `/discovedata?categoryid=…&source=QQ阅读` | 分类来自 `/discovestyle`，同样要 `source_type` |
| 全本 / 成人 / 情幻文学 / 肉文屋 / 禁漫天堂 / 18色漫 | 各自官网 | 18 禁清单 `nhSafeMode` |
| 漫画类（禁漫天堂/18色漫/开心看漫画/热辣漫画/漫客栈/龙天空/就爱文学）| 官网 | 漫画站点识别 `nhIsComicBook()`（按域名白名单）|
| UAA | 共享服 `/legado/explore/*` | 分类查询耗时随条数暴涨 ⇒ 默认 8 条/页（官方 20）防宿主 15s 超时 |
| 次元姬 | `/explore/init` | 所有数据要 JWT |
| 起点聚合 | `/legado/explore/menu` | — |
| 西瓜书屋 | 官网 | ⚠️ `base64Decode` 在新引擎上是 no-op ⇒ **P3 补丁** |
| 七猫 | 共享服 | — |
| 爱丽丝 | 中转 JSON（要令牌）+ 官网 HTML（免令牌）| ⚠️ 源站整站 520 过（Cloudflare）⇒ 部分分类**没法实测** |

---

## 7. 宿主能力探测与降级 ⭐⭐⭐

### 7.1 探测

```js
function nhNhHostCap() {
  var miss = [];
  function has(root, name) { try { return !!(root && typeof root[name] === 'function'); } catch (e) { return false; } }
  var list = [ [java,'ajax'], [java,'startBrowserAwait'], [source,'get'], [source,'put'],
               [source,'getVariable'], [source,'setVariable'], [cookie,'getCookie'], … ];
  for (…) if (!has(...)) miss.push(name);
  var out = 'missing=' + miss.join(',') + ' | noJvm=' + jvm.join(',');
  try { source.put('nhHostCaps', out); } catch (e) {}
  try { java.log('[NH-CAPS] ' + out); } catch (e) {}
  return out;
}
```

⇒ **探测结果写进书源变量 `nhHostCaps` + `java.log('[NH-CAPS] …')`** ⇒
⇒ 用户在宿主的引擎日志里搜 `NH-CAPS` 就能贴回来 ⇒ **第二轮对症适配** ⭐⭐⭐

### 7.2 降级铁律

> 「每个宿主 API 都**先探测再调用**，缺了就降级 —— **绝不抛 `ReferenceError`**」

⚠️ 因此每个对外函数都用 `typeof xxx !== 'undefined'` 兜底，例如：

```js
try { if (typeof java !== 'undefined' && java && typeof java.refreshExplore === 'function') { java.refreshExplore(); } } catch (e) {}
```

---

## 8. 缓存与作废策略 ⭐⭐⭐

宿主各有缓存键 ⇒ **改了变量必须让缓存失效**，否则「改了没反应」。

| 机制 | 做法 | 例子 |
|---|---|---|
| **变量 ⇒ 缓存键** | 让「变化的量」进缓存键 | 轻阅：`bookSourceUrl|find_source|find_tab` ⇒ 切台**同步写** `find_source`/`find_tab`（P2 补丁）⇒ 键变 ⇒ 失效 |
| **epoch 作废** | 把缓存键里的时间戳顶到现在 | `nhCyjTocEpoch`、`nhUaaTocEpoch` |
| **显式清空** | 改完变量顺手清缓存项 | `nhCyjCats`（分类缓存）、`nhMyMenu`（菜单缓存）|
| **宿主侧清缓存** | 宿主在筛选后清自己的分类缓存 | 轻阅：`invalidateKindsCache(source:)` |

⚠️⭐⭐⭐ **「切台没反应」是宿主与书源各修一半的经典案例**：

| 侧 | 问题 | 解法 |
|---|---|---|
| **书源侧** | 切台只改 `NH_D.src`，而宿主缓存键是 `…|find_source|find_tab` ⇒ 键不变 ⇒ 命中缓存 ⇒ 不重跑 | **P2 补丁**：同时写 `find_source`/`find_tab` |
| **宿主侧** | 缓存键只读书源变量槽，看不到站方 action 写的站方变量 ⇒ 键也不变 | 缓存键**同时读站方变量槽** + 筛选后**清缓存** |

⇒ **两侧都做 ⇒ 才稳** ⇒ 只做一侧 ⇒ 仍会「点了没反应」⭐⭐⭐

---

## 9. 短评 / 热评

- **短评**：段落级评论 / 「本章说」卡片 ⇒ `nhReviewSwitch`、`nhReviewRenderIOS`、`nhReviewPageUrl`、`nhReviewChapterCard`
- **热评**：神评论卡 ⇒ `nhReviewDecodeEntities`、`nhReviewNoteAttr`、`nhReviewGodN`
- 平台差异：`nhReviewHostIsIOS()`（iOS / 安卓两套口径）
- 开关：`source.get('nhReview')` / `nhReviewCommunity`

---

## 10. 构建流水线

```
原始附件（站方原版）
  └─ patch_source.py（幂等：每次从原始附件重新生成 ⇒ 反复跑字节恒定）
       ├─ P1 登录菜单静态平铺
       ├─ P2 切台同步写 find_source/find_tab
       ├─ P3 西瓜书屋 base64Decode no-op 的替代
       ├─ P4 次元姬 hexDecodeToString 缺失的替代
       ├─ P5 纯 JS 工具（nhHexDecode / nhB64DecodeBytes）上移到 jsLib 顶层
       ├─ P6 浏览器/视频：宿主是 no-op ⇒ 链接落到「看得见的地方」
       ├─ P7 能力探测表加入宿主缺的能力
       └─ P8 引擎每个 op 新建 bridge ⇒ jsLib 每次加载 ⇒ 顶层符号必须幂等
            ↓
     NovelHub聚合小说-轻阅新引擎适配.json
```

⚠️ **幂等是硬要求**：构建器每次都从**原始附件**重新生成 ⇒ 反复跑输出**字节恒定** ⇒ ⇒ 可以进版本库、可以逐字节比对。

---

## 11. 轻阅侧适配补丁清单（P1–P8）

| # | 主题 | 原因 | 做法 |
|---|---|---|---|
| **P1** | 登录菜单静态平铺 | 轻阅登录面板**不求值 `@js:`** | 把分组菜单拉平 + 加分隔行 |
| **P2** | 切台同步 `find_source`/`find_tab` | 轻阅缓存键 = `…\|find_source\|find_tab` | action 里**同时写**三个键 |
| **P3** | 西瓜书屋 `base64Decode` no-op | 轻阅引擎该 API 返回 null | 换纯 JS 实现 |
| **P4** | 次元姬 `hexDecodeToString` 不存在 | 同上 | 换纯 JS 实现 |
| **P5** | 纯 JS 工具上移 | jsLib 顶层才能被规则正文看到 | `nhHexDecode` / `nhB64DecodeBytes` |
| **P6** | 浏览器/视频 no-op | 宿主不弹浏览器 ⇒ 链接无处可去 | 落到宿主**看得见**的地方（可复制/系统打开）|
| **P7** | 能力探测表 | 让源自诊断能一眼看出缺什么 | 把缺失能力加进探测清单 |
| **P8** | 引擎每 op 新建 bridge | jsLib **每次都加载** | 顶层符号必须**幂等**（不重复注册/不累积状态）|

---

## 12. 宿主与书源的责任边界

| 能力 | 书源负责 | 宿主负责 |
|---|---|---|
| 筛选栏当前值 | 读 `infoMap['<标题>']` | **把选中值注入 `infoMap`** |
| 筛选写变量 | 写 `source.setVariable`（知道该写哪个键）| 提供 `infoMap.put` 回写 + `java.refreshExplore` |
| 切台生效 | 写 `find_source`/`find_tab`（宿主缓存键约定）| 缓存键含 `find_source`/`find_tab` + 筛选后清缓存 |
| 登录面板 | 提供 `loginUi` 条目与 action | 渲染 + 执行 action + 传递 `formValues` |
| 口令门禁 | `nhAuth()` 未解锁交白卷 | 提示用户去解锁 |
| 浏览器登录 | `java.startBrowserAwait` 等 | **真正实现浏览器并回传 Cookie/结果** |
| 能力差异 | 探测 + 降级（`nhHostCaps`）| 提供能力 + 让用户能贴回 `[NH-CAPS]` |

---

## 13. 已知缺口与风险

| 缺口 | 影响 | 现状 |
|---|---|---|
| 部分平台源站整站 520（Cloudflare）| 该平台分类**没法实测** | 路径照抄可用源的 `exploreUrl`，并在注释里标明 |
| 书旗 / QQ阅读 **不支持翻页** | 一次只 12~13 本 | 改用**子题材组**（`#NHGRP=a\|b\|c\|d`）逐词搜索合并去重 |
| UAA 分类查询随条数暴涨 | 宿主 15s 超时 | 默认 8 条/页（官方 20）|
| 18 色漫等敏感平台 | 内容风险 | `nhSafeMode` 开关（默认关）|
| 宿主能力差异 | 某些功能静默失效 | `nhHostCaps` 探测 + 降级 + 用户贴回日志 |

---

## 14. 演进规则

### 14.1 版本标记

| 标记 | 含义 |
|---|---|
| `[nove-slim]` | slim 化改造（正文搬 jsLib + 薄壳）|
| `[nove-adapt]` | 为**宿主适配**做的改动（跨宿主通用 ⇒ 尽量放这里）|
| `[v11x]` / `[v11z]` | 版本迭代标记（`v11x` = 第 11 版第 x 次）|

⇒ **约定**：宿主专属的适配尽量写成**宿主无关**的形式（如 P2 的「同步写 find_source/find_tab」只依赖宿主的缓存键约定，不依赖宿主实现）⇒ ⇒ 换宿主时**同一份源**也能用 ⭐⭐⭐

### 14.2 改源的铁律

1. ⭐⭐⭐ **先探测再调用**（不许直接调宿主 API）⇒ 缺了降级，不抛 `ReferenceError`
2. ⭐⭐⭐ **顶层符号带 `nh` 前缀**（jsLib 是间接 eval ⇒ 顶层进全局 ⇒ 撞名污染别的书源）
3. ⭐⭐⭐ **改变量 ⇒ 想清楚缓存键**（§8）⇒ 否则「改了没反应」
4. ⭐⭐⭐ **构建幂等**（每次从原始附件重新生成 ⇒ 字节恒定）
5. ⭐⭐⭐ **注释保留站方原话**（有信息量，别删）⇒ 站方注释解释了「为什么这么写」

---

## 15. 自检清单（出包前逐条过）

- [ ] `exploreUrl` 求值 ⇒ 分类数正常、**筛选栏条目数 > 0**
- [ ] 每个筛选 action 单测：改值 ⇒ `NH_D` 对应键变了 ⇒ `infoMap` 回写了 ⇒ `refreshExplore` 调了
- [ ] 切台 ⇒ 分类 URL 里的平台参数变了（不是缓存里的旧值）
- [ ] 未解锁 ⇒ `nhAuth()` 交白卷（不报错）；解锁后 ⇒ 出分类
- [ ] 各平台登录按钮 ⇒ 浏览器能开 ⇒ 登完 Cookie/token 读得回来
- [ ] 短评/热评 ⇒ iOS 与安卓两套口径都验
- [ ] `java.log('[NH-CAPS] …')` ⇒ 缺失能力清单符合预期
- [ ] 构建器**连跑两次 ⇒ 输出字节一致**
