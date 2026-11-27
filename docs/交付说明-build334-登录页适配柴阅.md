# 轻阅 Lite build334 —— 登录页换成柴阅的登录表单

日期：2026-11-27　｜　CFBundleVersion **334**　｜　包名 `com.qireaderlite.app`　｜　CI **45937156602**

> 用户：「**登录的 ui 也给我适配一下柴阅**」
> 选定：**柴阅原版观感（玻璃/浅色）** + **整页换成柴阅的登录页**

---

## 1. 搬了什么（柴阅 `App/Sources/Screens/Sources/SourceSheet.swift` 的登录三件套）

| 组件 | 内容 |
|---|---|
| `ChaiyueLoginForm` | **连续输入项合成一张卡片**（`CardGroup` + 行内标题 + 分隔线 + 行高 52）<br>**连续按钮排成网格**（列数取站方给的 `flexBasisPercent`）<br>按钮**图标按关键字映射**（退出/注册/扫码/检测/登录/后台/清空/更新/切换/服务器/设置/打赏/教程/发现…）<br>底部**主按钮条**（`AccentButton` + iOS 26 的 `safeAreaBar`）<br>滚动时隐藏键盘 |
| `ChaiyueLoginWebView` | **网页登录**（`loginUrl` 是 http 时走它 ⇒ 完成后把该站点的 Cookie 存给书源） |
| `BottomBar` | 柴阅的底部条（iOS 26 `safeAreaBar` / 更早 `safeAreaInset`） |

---

## 2. ⭐⭐⭐ 但轻阅的「真机修复」一个都没丢 ⭐⭐⭐

宿主那页有**柴阅没有**的能力（全是真机修过的）⇒ **换观感 ≠ 换能力** ⇒ 行的取法与执行仍留在宿主手里：

| 能力 | 为什么必须留 |
|---|---|
| 表单值**写值即落盘** | 以前关掉面板就没了（用户反馈）⇒ 重进/重启还在 ⭐⭐⭐ |
| 番茄 sessionid **自动抓** | 用户在浏览器登录过 ⇒ 不用手抄 token（用户反馈）⭐⭐⭐ |
| **「退出登录」**按钮 | 有些源的登录态要单独退 ⭐⭐⭐ |
| **引擎急救**（重置引擎） | 站方 JS 卡死时点它，不用重装 App（用户反馈）⭐⭐⭐ |
| **登录状态检测** | 登录成没成的真话 ⭐⭐⭐ |
| **站方原文** | 站方只吐 `java.toast` ⇒ 原文收回来给用户看 ⭐⭐⭐ |
| **先静态后柴阅**的秒开 | 柴阅的 `resolveLoginRows` 对静态源可能返回**预设行** ⇒ 会把站方真正的按钮顶掉 ⇒ 静态优先 ⭐⭐⭐ |

⇒ 门禁第③组逐条钉住这 7 项 ⇒ **少一条就红** ⭐⭐⭐

---

## 3. 与上游的 diff（务必看）

1. **剥掉柴阅的「大灰狼账号体系」**：`WolfSheet` / `WolfAccount` / `signedIn` / `switching` /
   `enteringKey` / `keyInput` / `loginWithKey` / `accountSection` / `wolfBase` / `signOutFirst`
   ⇒ 那套在柴阅 `Screens/Explore/WolfCenter.swift`（721 行）⇒ **轻阅不搬**
   ⇒ ⇒ 「已登录态卡片」「用密钥登录」在轻阅里没有 ⇒ 登录态检测仍由宿主承担 ⭐⭐⭐
2. **不依赖 `AppModel`**：柴阅用 `app.island.show` 弹 toast ⇒ 改成**回调** `onToast(icon, message, danger)` ⇒ 宿主接到自己的 toast ⭐⭐⭐
3. **执行不交给柴阅 target**：宿主保留自己的执行（带超时 / 番茄自动抓 / 站方原文）⇒ 组件做成「**宿主给行 + 宿主执行**」⭐⭐⭐
4. **配色 = 柴阅原版**（`Tok` 玻璃/浅色，用户明确选）⇒ 但保留 `Palette` 入口 ⇒ 将来要「宿主深色」时一行切换 ⭐⭐⭐

---

## 4. 命名纪律（这轮又踩了一次，已固化）

宿主**不能** `import ChaiyueReader` ⇒ 它 `@_exported import ChaiyueModels`
⇒ 会把柴阅的 `Book` / `BookSource` 带进宿主命名空间 ⇒ **与宿主同名类型 ambiguous** ⭐⭐⭐
⇒ 走 `LegadoEngine` 门面转发：`ChaiyueLoginFormBridge` + `LegadoEngineHost.LoginRow`
⇒ 而 `LoginRow` 的 **public init** 必须放在 **`ChaiyueEngine` 模块**（宿主经别名调用 ⇒ 才可见）⭐⭐⭐

---

## 5. 门禁

`test/reader-chaiyue-login.test.js`（**22 项 / 3 组**）：
① 柴阅的组件在场（卡片 / 网格 / 图标映射 / 主按钮 / BottomBar / 网页登录）
② 宿主走门面转发（不许直接 import ChaiyueReader；`LoginRow` 别名 + public init 都在）
③ **轻阅的 7 项真机修复一个都不能少** ⭐⭐⭐

---

## 6. 验证

- CI **45937156602**（main，commit `ac743da`）
- 门禁：新门禁 22/22；阅读器相关 42/47/54/39 全绿
- 产物：`QingYue-build334.zip`（+ `-noprov`）⇒ 解包验 **CFBundleVersion = 334** ✔

---

## 7. ⚠️⚠️⚠️ build334 的**第 4 轮**修复（CI335/336 连续两红 ⇒ 本轮定案）

### 7.1 CI336 的真凶：`LoginRow` 的 `public init` **不能放 extension**

柴阅的 `LoginRow`（`ChaiyueEngine/Engine/WebBook.swift`）是 **struct 且带自定义 `init(from:)`**
⇒ **memberwise init 被抑制**
⇒ **extension 里的 init 不能给存储属性赋值**（Swift 要求它调 `self.init`）
⇒ 而 `init(from:)` 要 decoder ⇒ ⇒ **extension 这条路根本不通** ⭐⭐⭐

CI336 实锤报错：
```
LoginRow+PublicInit.swift:29: error: 'self' used before 'self.init' call
LoginRow+PublicInit.swift:36: error: 'self.init' isn't called on all paths before returning from initializer
```

⇒ **正解：把 `public init` 写进 `LoginRow` 的【主声明】**（`WebBook.swift`）⇒ 类型与 init 同模块 ⇒ 一律可用 ⭐⭐⭐

⚠️ **顺带纠正一条错判据**（之前写进门禁注释里的）：
> 「init 必须定义在宿主能看见的模块里（`LegadoEngine`），否则 `initializer is inaccessible`」

**这是错的** ⭐⭐⭐：`public init` 只要与类型**同模块**即可；
宿主只 `import LegadoEngine`、经 typealias `LegadoEngineHost.LoginRow` **照样能调**
⇒ 已在沙盒用 swiftc 做了**三模块实验**（A=定义类型+init / B=门面 typealias / C=只 import B）⇒ **C 编过** ⭐⭐⭐

### 7.2 柴阅登录表单**此前从未编译过** ⇒ 里面有两个「用了没定义」

`ChaiyueLoginForm.swift` 里：
- `running`（245 行 `if running == index`）**全文没有定义** ⇒ `cannot find 'running' in scope`
- `run(row, index:)`（241 行被调用）**全文没有定义** ⇒ `cannot find 'run' in scope`

⇒ 本轮补齐（`running` 按 **action** 反查行号；`run` 把 `formData()` 带过去）⭐⭐⭐

### 7.3 表单键语义修正：**技术名** ≠ **人话名**

宿主原来在求值完 `viewName` 后**直接改写了 `Field.name`** ⇒ 表单值用「人话」当键
⇒ 对 `viewName` 型书源（技术名如 `jmModeN`）⇒ **站方脚本读 `result['jmModeN']` 读不到 ⇒ 登录参数全错** ⭐⭐⭐

⇒ 本轮起：`Field` 同时带 `name`（技术名 = 表单键）与 `displayName`（人话名 = 显示）
⇒ 与柴阅 `LoginRow` 的 `name` / `viewName` 语义**逐字对齐** ⭐⭐⭐

### 7.4 另外几处必炸点

- 宿主 `onRun:` / `onSubmit:` 是 **escaping closure** ⇒ 必须写 `self.` ⇒ 否则编译不过 ⭐⭐⭐
- 门面 `ChaiyueLoginFormBridge.body` **显式标 `@MainActor`**（柴阅 target 是 Swift 6 + `-default-isolation MainActor`）⭐⭐⭐
- 旧的**手写登录表单**（`loginFields` / `actionButtonsGrid`）已删（整页换成柴阅的 ⇒ 成死代码）⭐⭐⭐
- 转圈从「按行名匹配」改成「**按 action 匹配**」（柴阅表单要的是动作标识）⭐⭐⭐

### 7.5 门禁

- `test/reader-chaiyue-login.test.js`：**22 → 42 项**（新增 ④ 表单自身站得住 / ⑤ 表单键语义）
- ⭐⭐⭐ **新增变异对照** `test/mutation-chaiyue-login-init.sh`（**5/5**）：
  三种变异（把 init 挪回 extension / 删掉 `running` / 让显示名顶掉技术名）⇒ **门禁必须红** ⇒ 复原必须绿 ⭐⭐⭐

### 7.6 CI337（run `45941151446`）：编译步骤**通过**，打包步骤失败 ⇒ 真因在编译日志里

- ⚠️ **CI 的「编译」step 显示 success，实际有 3 个 failures** ⇒ 因为那步用了 `|| true`（退出码被吞）
  ⇒ **打包 step 才暴露**：「构建产物不完整：缺可执行文件 QingYue」⭐⭐⭐
  ⇒ ⇒ **教训：CI step 显示 success 不等于编过了 ⇒ 必须看归档的 b.log**（artifact `build-log`）⭐⭐⭐
- 下载 b.log 后，**全部 7 条错误都在 `ChaiyueLoginForm.swift`，且是同一个根因**：
  ```swift
  public var onToast: (String, String, Bool) = { _, _, _ in }   // ❌ 元组型
  public var onToast: (String, String, Bool) -> Void = { _, _, _ in }  // ✅ 函数型
  ```
  ⇒ 元组型 ⇒ 默认值（3 参闭包）塞不进去 ⇒ 报 `cannot convert value of type '(_, _, _) -> ()'`
  ⇒ 且 `onToast("key", "已保存登录状态", false)` 这种**调用**写法也报
  ⇒ **一处写错 ⇒ 7 条报错** ⇒ 容易误以为是好几个独立问题 ⭐⭐⭐
- ⇒ **已加门禁**：`reader-chaiyue-login` ④ 扫「闭包属性/参数的类型是元组（`)` 后面没有 `->`）」⇒ Linux 就能抓 ⭐⭐⭐
  ⇒ 变异对照新增第 4 条（把 onToast 改回元组型 ⇒ 门禁必须红）⇒ **6/6** ⭐⭐⭐
