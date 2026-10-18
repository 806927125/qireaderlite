# 轻阅 Lite

一个 iOS 阅读客户端，直接吃 **Legado / 阅读** 的书源 JSON。

不是套壳，是把 Legado 的规则语言（Jsoup 选择器、正则、JSONPath、XPath、`@js:`、
`&&`/`||` 回退链）实打实重新实现了一遍，然后原生地渲染。

---

## 架构

```
┌─────────────────────────────────────────────┐
│  SwiftUI 界面（书架/发现/搜索/详情/目录/阅读）  │  ← 全部原生
├─────────────────────────────────────────────┤
│  SourceService   异步调用 + JSON 编解码        │
├─────────────────────────────────────────────┤
│  RuleSandbox     WKWebView（隐藏，零 UI）      │
│                  ↕ JS 消息                     │
│  NativeBridge    HTTP / Cookie / 缓存 / 日志    │  ← 出网走原生
├─────────────────────────────────────────────┤
│  JS 规则引擎                                     │
│   jsoup-compat  Jsoup 选择器 → WebKit DOM      │
│   jsonpath       JSONPath 子集                  │
│   org-jsoup      org.jsoup.* 兼容层              │
│   java-api       java.* 70 个方法              │
│   rule-analyzer  规则解释器                      │
│   engine         搜索/发现/详情/目录/正文 调度     │
└─────────────────────────────────────────────┘
```

**为什么不把 UI 也塞进 WebView**（栖阅走的路）：

- 14MB JS 拖慢冷启动、常驻内存
- 拿不到 UIKit，滚动/翻页/字体渲染全得在 HTML 里手搓
  —— 栖阅为此得单独抽一个 `reader-scroll-core.js`

所以这里 WKWebView **只当 JS 虚拟机**，跑完规则吐 JSON 回来，界面全原生。

**为什么 HTML 解析不用 Kanna**：
引擎直接用 WKWebView 自带的 `DOMParser`。只要补上 Jsoup 有、DOM 没有的那部分
（`:contains()` / `:matches()` / `[attr^=]` / `class.x@tag.y` 简写），就够用了。
Swift 侧一行 HTML 解析代码都不用写，零原生依赖。

---

## 怎么编译出 IPA

`.ipa` 本质是 Xcode 归档 + 签名的产物，**必须 macOS** —— 但你**不需要自己有一台**，
云端 CI 会给你一台。

### 路线 1 · Codemagic（最省事，推荐没 Mac 的走这条）

1. 打开 [codemagic.io](https://codemagic.io)，用 GitHub 登录
2. **Add application** → 选这个仓库 → 它会自己读 `codemagic.yaml`
3. 右边点 **Start build**
4. 跑完网页上直接下载 IPA

全程网页点两下，不用碰任何配置文件。免费 500 分钟/月，一次构建 3~5 分钟。

### 路线 2 · GitHub Actions

推到 GitHub → **Actions** → 「出 IPA」→ Run workflow → Artifacts 下载。

- 公开仓库：macOS runner 免费无限
- 私有仓库：macOS 按 10 倍算，免费额度 2000 分钟 ≈ 200 次构建，够用

### 路线 3 · 本地（你有 Mac 时）

```bash
./scripts/build-ipa.sh
```

产物在 `build/轻阅-YYYYMMDD.ipa`，是**免签包**。

### 装到手机

免签包要用 AltStore / Sideloadly / 爱思 / 巨魔 之类导入。
免费 Apple ID 签的 App **7 天要重签一次**。

想和手机上的其它 App 共存，改 `project.pbxproj` 里的
`PRODUCT_BUNDLE_IDENTIFIER = com.qireaderlite.app` 换成一个新值再签。

---

## 目录

```
QiReaderLite/
├── App/            入口、主题、Tab 容器
├── Core/
│   ├── BookSource.swift    书源模型 + 容错解析（对象/数组/多对象拼接都吃）
│   ├── Book.swift          书 / 章 / 书架条目
│   ├── Store.swift         书源仓库、书架、正文磁盘缓存
│   ├── RuleSandbox.swift   WKWebView 沙盒 + 原生桥
│   └── SourceService.swift Swift ↔ 引擎 的唯一入口
├── Features/       各界面
└── Resources/
    ├── Info.plist          ATS 全放开（书源大量是 HTTP 明文站）
    └── engine/             JS 规则引擎
```

---

## 测试

引擎部分可以脱离设备跑（Node + jsdom）：

```bash
npm install
node test/rules.test.js           # 规则解释器 39 项
node test/e2e.test.js             # 端到端全链路 37 项
node test/explore-fallback.test.js # 发现页规则回退 19 项
node test/explore-live.js         # 发现页真站实测（需能出网）
node test/explore-probe.js 60     # 批量扫 60 个带发现规则的源

# Swift 类型检查（Linux 上也能跑，见下）
SWIFT_BIN=/path/to/swiftc ./test/linux-typecheck.sh
python3 test/swift-structure.py   # Swift 结构校验
```

### Linux 上也能真编译 Swift

`.ipa` 需要 macOS，但**类型检查不需要**。`test/linux-typecheck.sh` 会用
Linux 版 swiftc 真正检查 Foundation 层（书源模型、书籍模型、存储层、
SourceService、RuleSandbox），配合 `test/linux-shims/` 里的最小替身模块。

覆盖得到：类型不匹配、成员不存在、参数标签错、可选性用错、协议 conformance 漏写。
覆盖不到：各 SwiftUI 页面（SwiftUI 的泛型修饰符链没法用假模块验），
以及 WebKit API 用法本身（shim 签名是照记忆写的，不等于真实 SDK）。

**这个门禁确实抓到了 6 个真编译错误**，都是 CI 第一次跑就会红的：
`BookLite.id` 引用不存在的成员、`invoke` 参数标签多了 `payload:`、
`evaluateJavaScript` 走 async 重载却漏 `await`、`httpAdditionalHeaders`
可选属性直接下标赋值、`WKNavigationDelegate` 的 `@MainActor` 要求被
`nonisolated` 实现、`WKScriptMessageHandler` conformance 漏声明。

装了工具链之后：

```bash
curl -sL -o swift.tar.gz \
  https://download.swift.org/swift-6.1.2-release/debian12/swift-6.1.2-RELEASE/swift-6.1.2-RELEASE-debian12.tar.gz
tar xzf swift.tar.gz
export SWIFT_BIN=$PWD/swift-6.1.2-RELEASE-debian12/usr/bin/swiftc
export LD_LIBRARY_PATH=$PWD/swift-6.1.2-RELEASE-debian12/usr/lib/swift/linux:$LD_LIBRARY_PATH
```

端到端测试用一套假站点 + 一份真实写法的书源，完整跑通
**搜索 → 详情 → 目录（跨两页）→ 正文（含广告行过滤）→ 发现**，并断言请求序列。

---

## 真实书源兼容性（实测数据）

拿 [aoaostar/legado](https://github.com/aoaostar/legado) 的 **9060 个书源、156011 条规则**
跑 `node test/compat-corpus.js` 体检：

```
有问题的规则 1206 / 156011 = 0.77%
```

已覆盖（按语料出现频次从高到低）：

| 语法 | 语料条数 |
|---|---|
| `a.1` / `span.0` / `dd.-1` 标签+下标索引 | 16881 |
| `$1` / `$2` 跨字段捕获组 | 15502 |
| JSONPath（含 `$..` 递归、切片、负下标、过滤） | 14954 |
| 裸正则列表规则 `:<tr…>(.*?)</a>` | 13375 |
| `\|\|` / `&&` 回退链 | 11182 |
| `@js:` | 4214 |
| URL 模板 / POST 搜索（`{"method":"POST","body":…}`） | 3099 |
| `##正则##替换##` | 2732 |
| `{{表达式}}` 插值（`java.put/get`、`$.x`、`book.x`、`Math.*`） | ~3000 |
| XPath | 1160 |
| `@css:` 前缀 | 533 |

已知不支持（约 0.8%，都是长尾）：

- `JavaImporter` / `java.util.*` —— JVM 专有，iOS 上没法也不该支持
- `java.HMacHex` / `java.desEncodeToBase64String` / `java.setContent` 等个别冷门方法
- XPath 命名空间 `::`
- `loginUrl` / `loginUi` 登录流程
- 书源自定义变量（`{{ho}}` 这种只在某个源内部定义的）

---

## 引擎覆盖范围

| Legado 特性 | 支持 |
|---|---|
| Jsoup 选择器（含 `:contains` `:matches` `[attr^=]`） | ✅ |
| `class.x@tag.y@attr` 简写链、中文类名 | ✅ |
| `##正则##替换##替换` | ✅ |
| JSONPath（`$.a.b[0]`, `$..x`） | ✅ |
| XPath（Safari `document.evaluate`） | ✅ |
| `@js:` / `<js>` 表达式与 return 两种写法 | ✅ |
| `&&` / `||` 回退链、数组多行规则 | ✅ |
| `org.jsoup.*` 兼容层 | ✅ |
| `java.*`（ajax/get/post/base64/md5/sha1/cacheFile…） | ✅ 常用 40+ |
| 书源 `header`（含 `,{"headers":…}` 单 URL 挂头） | ✅ |
| `jsLib` 自定义函数库 | ✅ |
| `webJs` 正文解密 | ✅ |
| 目录串行翻页 + 下标跨页累计 | ✅ |
| 章节内分页自动续接 | ✅ |
| `exploreUrl` 返回数组 / JSON 字符串 / 纯文本分类 | ✅ |
| `exploreUrl` 直接是一段 JSON 数组 | ✅ |
| 发现页规则为空时回退 `ruleSearch` | ✅ |
| 登录 `loginUrl`、Cookie 罐、付费章节 | ❌ MVP 未做 |
| 交互式浏览器（`java.webView`） | ❌ 明确报错，不假装成功 |

---

## 发现页（Explore）是怎么对齐 Legado 的

发现页踩过的坑比搜索多，因为「分类」和「书列表」是**两套独立规则**，
而绝大多数书源只认真写了一套。照 Legado 的源码抄，三条规则缺一不可：

### ① 分类从哪来

Legado `BookSourceExtensions.exploreKinds()`：

| `exploreUrl` 的写法 | 怎么解析 |
|---|---|
| `@js:` / `<js>` | 先跑 JS，再看结果是**JSON 数组**还是**纯文本** |
| 一整段 JSON 数组 | 直接当 `ExploreKind[]` 解析（`[{"title":"玄幻","url":"…"}]`） |
| 纯文本 | 按 `(&&|\n)+` 切开，每行 `分类名::URL` |

漏掉「一整段 JSON 数组」这一支，症状是**只解析出 1 个分类**，
而且那 1 个分类的标题是整段 JSON、URL 是空的 —— 点进去必然空列表。

### ② 书列表用哪套规则 ★ 最关键

Legado `BookList.kt`：

```kotlin
val bookListRule: BookListRule = when {
    isSearch -> bookSource.getSearchRule()
    bookSource.getExploreRule().bookList.isNullOrBlank() -> bookSource.getSearchRule()
    else -> bookSource.getExploreRule()
}
```

**回退换的是整份规则对象**，不是只换 `bookList` —— 名字、作者、封面、
书籍 URL 全跟着换成 `ruleSearch` 的。只换 `bookList` 的话，
列表能出来但每本书没名字，App 里就是一堆空行。

语料里 4953 个源带 `exploreUrl`，其中大量 `ruleExplore` 就是 `{}`
（写书源的人只填了分类 URL，忘了写发现规则）。不实现这条回退，
这些源的发现页**永远是空的**。

### ③ 分类 URL 里的 `{{page}}`

`玄幻::/sort1/{{page}}/` 这种相对 URL 会被补成绝对地址，
`{{page}}` 在发请求前展开 —— 注意 `new URL()` 会把 `{` `}` 百分号编码，
所以补全绝对地址这步必须绕开 `URL` 构造函数。

### 实测

`node test/explore-live.js` 拿真站跑（沙盒在境外，部分站被墙）：

```
✓ 👍玄幻阁    (http://www.xuanhuange.net)   11 个分类 → 出书 30 本
✓ 🔖玄幻阁    (http://www.xuankuge.com)     10 个分类 → 出书 30 本
✓ 📚 玄幻文学  (https://m.xhwx3.com)         7 个分类 → 出书
✓ 小说屋      (http://www.xiaoshuowu.com)   13 个分类 → 出书 30 本
✗ 小说屋      (http://www.xs5.la/)          站方连接超时（不是引擎问题）
✗ 闪舞小说    (https://www.35xss.com)       站方 503（不是引擎问题）
```

---

## 已知限制

- **MVP 只做阅读链路**，没有 TTS、缓存整本、下载、书源设计器、云同步
- 免签包 7 天过期，付费开发者账号可签 1 年
- `org.jsoup.Connection` 只做了够用的一层，复杂的 Cookie 注入可能不够
- 书源的 `loginUrl` 登录流程没实现，涉及登录的书源用不了

---

## 授权

- 引擎代码：原创
- `sha1.js` 内联自 [js-sha1](https://github.com/emn178/js-sha1) 0.7.0（MIT）
  —— 手写 SHA-1 时把 Ch 化简成 `d^(b&~d)` 这类错误会**静默**返回错值，
  签名错的请求会被站方当反爬拦掉，症状是「搜不到书」，根因完全看不出来
