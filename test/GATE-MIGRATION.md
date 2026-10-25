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
