# ⭐ 门禁迁移规范（老 JS 引擎物理删除后）

> 2026-10-25 · 轻阅 Lite · 老引擎（`QiReaderLite/Resources/engine/*.js` + `test/harness.js`）已物理删除
> ⇒ 门禁必须**改跑新引擎**（`/workspace/legado-engine` 的 Swift 实现）

## 0. 一句话

**门禁的 `require('./harness')` 已改成 `require('./new-engine-harness')`（已完成）。**
你只需要把**假服务器**从老的 JS 层 `nativeMock` 改成新的**声明式 routes**，并把**老引擎实现细节断言**退休。

## 1. 沙盒 API（`test/new-engine-harness.js`）

```js
const { createSandbox, engineAvailable } = require('./new-engine-harness');
const { win } = createSandbox({ routes: [ /* 见下 */ ] });
```

### 1.1 假服务器（**必须改**）

**老写法（已失效）**：
```js
const reqs = [];
const nativeMock = async (fn, args) => {
  if (fn === 'request') { reqs.push(String(args.url || ''));
    return { ok: true, code: 200, url: args.url, headers: {}, body: '{"ok":1}' }; }
  if (fn === 'log') return { ok: true };
  return { ok: true, value: '' };
};
const { win } = createSandbox({ nativeMock });
```

**新写法（声明式路由）**：
```js
const { win, sandbox } = createSandbox({
  routes: [
    { match: 'a.example.com', status: 502, body: '<html>502</html>' },
    { match: '/p', status: 200, body: '{"ok":1}' },
  ],
});
// ⭐ 请求记录从 sandbox 拿（引擎回传的）
const reqs = sandbox.__requests;
```

⭐ 路由规则：
- `match`：**子串匹配**（对 URL 去 query 后匹配；也可写 host 片段）
- **按顺序匹配，第一条命中即用**
- 未命中 ⇒ **404**（明确失败，不静默 200 ⇒ 不会假绿）
- `status` 非 2xx ⇒ `java.ajax` 返回 **`请求失败(<code>): <url>`** 字符串
  （与真机 `SourceEngine.ajax` 同语义 ⇒ 站方 `JSON.parse` 抛 ⇒ catch 换线）

### 1.2 求值入口

| 调用 | 走引擎的 |
|---|---|
| `win.eval("window.__qrInvoke('explore', {…})")` | `--op` |
| `win.eval("window.QR.rule.runJs(code, {})")` | `--js` |
| `win.eval("任意 JS")` | `--js`（**宿主 API 可用**：`java.*` / `source.*` / `book.*`） |
| `win.__qrInvoke('explore', {…})` | `--op`（直调） |

⭐ **`--op` 支持的 op**：`explore` / `exploreKinds` / `bookInfo` / `toc` / `content` / `login` / `loginProbe` / `sourceVars` / `sourceHosts` / `filterAction` / `explain` / `explainToc` / `search`
（payload 里的 `routes` 会被透传给引擎 ⇒ 假服务器可用）

## 2. 必改的两类断言

### 2.1 老引擎实现细节断言 ⇒ **退休**

老引擎有一堆**实现细节**（不是语义），例如：
- `MAX_PASS` 轮数上限、`delete out[u]`、`hexDecodeToString 挑「像人话」`
- `rule-analyzer.js` / `java-api.js` / `engine.js` 里的**具体函数名与代码片段**

⭐ 这些**老引擎已经没了** ⇒ 新引擎**没有等价物**（新引擎是同步的，压根不需要「轮数上限」那套补丁）。
⇒ **退休它们，不损失语义覆盖**。⇒ 用下面这段注释替换整段：

```js
  // ⭐⭐⭐⭐⭐ **老引擎实现细节断言已退休**（2026-10-25 老 JS 引擎物理删除）
  //   ⇒ 以前这些断言验的是**老引擎的函数名/代码片段** ⇒ 那是**实现细节**，不是语义
  //   ⇒ 老引擎退役后**没有等价物** ⇒ 退休**不损失语义覆盖** ⭐⭐⭐
  //   ⇒ **语义覆盖在上面的【真跑段】**（现在跑的是【新引擎】）⇒ 覆盖不丢 ⭐⭐⭐
  //   ⇒ 等价断言在【引擎仓的 swift test】（266 项）与真机上 ⭐⭐⭐
```

### 2.2 读老引擎 JS 源码的静态断言 ⇒ **改读新引擎 Swift 源码**

路径已批量改好（`ENGINE` 常量现在指向 `../legado-engine/Sources/LegadoCore`）。
⭐ **如果断言的内容是「新引擎也要有同样的能力」** ⇒ 保留断言、改成对新引擎的等价描述。
⭐ **如果断言的是老引擎的私有细节** ⇒ 退休。

## 3. 硬规矩（违反了就是假绿）

1. ⭐ **不许把失败改成通过**：老断言不成立时，**要么改造成新引擎的等价断言，要么退休并写明理由**。**不许删掉断言行**。
2. ⭐ **不许用 `!` 强解包**（用 `try { … } catch { … }`）⇒ 崩了能指名道姓。
3. ⭐ **断言要作用于「从源文件解析出来的规则本身」**，不能复述实现意图。
4. ⭐ **「没验到」≠「通过」**：引擎不可用 / 需要真实 HTTP ⇒ **显式 SKIP** 并说明。
5. ⭐ **每条断言都要问「把实现改坏它会不会红」**（平凡通过 = 恒真 = 抓不到 bug）。
6. ⭐ **注释单独一行**：不许「代码 + `//` 行注释」（会吃掉下一行）。

## 4. 收工自检

```bash
cd /workspace/qireaderlite
node test/<你的门禁>.test.js     # 必须 0 失败
bash test/run-all-gates.sh        # 全量
```

⭐ 改完把你负责的门禁**逐个跑一遍**，把结果贴出来。

---

## 5. 2026-10-26 收官：全量门禁 **1913 通过 / 0 失败**（1 个明说跳过）

### 5.1 本轮收掉的门禁失败（从 15 个 → 0 个）

| 门禁 | 之前的症状 | 真因 | 修法 |
|---|---|---|---|
| `js-backend-parity` | ❌ 27/8 | 门禁按**旧结构**断言（`isObjectLiteral` / `hasTopLevelReturn` / `( trimmed )`）⇒ 引擎重构后必然红 | 改成断言**更强的新不变量**：形态脚本文本**只有一处生成** + 三形态顺序 + **只有语法错才换形态** + 执行成功就 break ⇒ 42/0 ⇒ **变异测试验过能红** ⭐⭐⭐ |
| `swift 原生层` | ❌ 编不过 | `AppPaths.swift` / `HostTools.swift` **不在编译列表里** ⇒ 「cannot find 'AppPaths' in scope」 | 三组编译列表都补上 ⇒ 244/0 ⭐⭐⭐ |
| `swift 原生层`（另一处） | ❌ 重复声明 | **stub 里留着和真文件同名的 `CookieJar` / `CacheFiles`** ⇒ 把真类型遮住 | 删掉 stub 里的同名类型（stub 只许留「真文件里没有的」）⭐⭐⭐ |
| `jm-novel-e2e` | ❌ 1/1 | `sources/JM小说.json` 不在仓库里（用户上传过） | 补进 `sources/` ⇒ **11/0**（分类 13 个 · 出书 15 本）⭐⭐⭐ |
| `engine-api-parity` | ⏭ 跳过 | 读**老引擎已删除的文件** ⇒ ENOENT 崩 | **整个重写**（见 5.2）⇒ 8/0 |

⭐⭐⭐ **根因分类**：这 5 个里 **4 个是同一个病** ——「**门禁盖不住我改的东西**」
⇒ 编译列表漏文件 / stub 遮住真类型 / 门禁按旧结构断言 / 门禁读已删除的文件。

### 5.2 `engine-api-parity` 重写：把「跳过」变成「真能抓」

⭐ 老门禁对比的是**栖阅的 `jsoup_bridge.js`** 和**轻阅老 JS 引擎的文件** ⇒ 老引擎退役后**必崩** ⇒ 一直「跳过」。
⇒ 新门禁钉三件事：
1. **参考面**：栖阅那份 `jsoup_bridge.js` 暴露了哪些类型
2. **真实用量**：**125 源语料**里站方**规则代码**（不是注释！）真的用了哪些
3. **新引擎面**：这些类型在**新引擎的 JS 环境**里**运行时**存不存在

⇒ 判定三档：语料在用 + 引擎有 ⇒ ✅ ｜ 语料在用 + **老引擎有** ⇒ ⭐「**待吸收**」（列出来，不算红，但不许悄悄长大）｜ 其余 ⇒ **红**。

#### ⭐⭐⭐⭐⭐ 抓到的真发现：`org.jsoup` 是**老引擎退役时丢的能力**
- **125 源里 4 个源在规则代码里真用** `org.jsoup.Jsoup.parse(...)`（#32 目录 / #37 目录 / #46 发现页 / NovelHub 聚合源）
  ⇒ 新引擎**没有 `org` 全局** ⇒ **这些源的目录/发现页会炸** ⭐⭐⭐⭐⭐
- 而**栖阅自己也不支持**（NovelHub 源里的注释实证：「org.jsoup 在栖阅 iOS 的 JSC 上不工作」）
  ⇒ ⇒ **相对栖阅不算缺口**（两边一样）⇒ ⇒ **相对轻阅老引擎是真缺口** ⇒ ⇒ 记进「待吸收」清单
  ⇒ ⇒ 对应用户那条规矩：「**老引擎有的、新引擎没有的 ⇒ 吸收进新的**」
- ⭐ 栖阅声明但语料 0 用量的那些（`JXDocument` / `JXNode` / `org.jsoup.nodes.*`…）⇒ **理论缺口** ⇒ 现在不补 ⇒ 语料里一出现就红

#### ⭐⭐⭐ 门禁自己踩的两个「测量方式骗人」的坑（都是变异测试抓到的）
1. **探针把「报错」当成「有」**：`typeof (org.jsoup.X)` 在引擎里**抛 ReferenceError** ⇒ 探针返回 `'ERR: …'`
   ⇒ 被当成「存在」⇒ ⇒ **缺口被自己骗过去** ⇒ 修：判据 = 「既不是 undefined、也没报错」才算有 ⭐⭐⭐
2. **收集器漏了 `bookList`** ⇒ 列表规则**根本没被扫** ⇒ 「语料在用 org.jsoup」这条**测不到** ⇒ 门禁恒绿
   ⇒ 修：**`rule*` 对象里的东西一律当代码**（不靠手写清单 ⇒ 新加的规则字段自动被扫到）⭐⭐⭐
   ⇒ 顺手加**防漏自检**（按【源】配对 ⇒ 每个源自带的 bookList 必须在它自己的收集结果里 ⇒ 82/82）

### 5.3 引擎侧那三个真凶（详见 `legado-engine` 仓的 `JSEvalShape.swift` 注释）

⭐ **`toJSON` 把数组/对象内容全丢了**（`as? JSValue` 永远失败）⇒ 真机「0 本书 / 字段全空」
⭐ **JSC 顶层脚本的 `let` 是全局词法声明** ⇒ 第二次跑重复声明 ⇒ **静默空** ⇒ 改用直接 eval
⭐ **形态链自创了** ⇒ 换成**老引擎同款三形态 + 只在语法错时换形态** ⇒ 两个后端**同一份脚本文本**
