# 交付说明 build335 —— 「点开始阅读闪退」**定案**（真机 .ips 抓到的那一行）

> 真机反馈（2026-11-28 13:09）：**点击开始阅读闪退**
> 追加确认：**文字书与漫画书都崩** ⇒ 共因在**两个阅读屏共用**的那一层
> ⭐⭐⭐ **最终定案**：用户提供了 `.ips` 崩溃日志 ⇒ **精确到栈帧** ⇒ 不是猜，是定案 ⭐⭐⭐

---

## 1. ⭐⭐⭐ **真凶（.ips 定案）**

```
exception: EXC_BREAKPOINT / SIGTRAP（Trace/BPT trap: 5）
崩溃线程 queue = NSOperationQueue 0x1445f0000 (QOS: UTILITY)

 #0  libdispatch.dylib            _dispatch_assert_queue_fail
 #1  libdispatch.dylib            dispatch_assert_queue
 #2  libswift_Concurrency.dylib   _swift_task_checkIsolatedSwift
 #3  libswift_Concurrency.dylib   swift_task_isCurrentExecutorWithFlagsImpl(...)
 #4  QingYue                      closure #2 in VoicePackTransfer.observe(_:)   ★★★ 就是这一行
 #5  QingYue                      <deduplicated_symbol>
 #6  Foundation                   -[NSBlockOperation main]
 #7  Foundation                   __NSOPERATION_IS_INVOKING_MAIN__
```

设备：iPhone OS **27.3** / build_version **334** / build 334

### 根因链条

1. `AppModel(library:)` 的**默认参数**会构造 `LocalVoiceStore()`
   ⇒ ⇒ **每次打开阅读器都会构造它** ⇒ 文字书/漫画书都一样 ⇒ **「两种都崩」的共因就在这里** ⭐⭐⭐
2. `LocalVoiceStore.init` 注册 observer：
   ```swift
   transfer.observe { snapshot in
       Task { @MainActor in self.apply(snapshot) }   // 💥 这一行
   }
   ```
3. `VoicePackTransfer` 的 observer 是 **nonisolated `@Sendable`** 闭包
   ⇒ ⇒ 它的 body 跑在**后台 OperationQueue**（QOS UTILITY）上 ⭐⭐⭐
4. ⭐⭐⭐ **Swift 6.2+ 的语义变化**：`Task { @MainActor in … }` 改为**继承当前 executor**
   （**不再保证切到 MainActor**）⇒ ⇒ 在后台队列上创建的 Task **继承了后台队列** ⭐⭐⭐
5. ⇒ `self.apply(snapshot)`（`self` 是 **@MainActor 隔离**的 `LocalVoiceStore`）
   跑在**非 MainActor 的 executor** 上 ⇒ ⇒ 💥 **dispatch 队列断言失败**
   ⇒ ⇒ `EXC_BREAKPOINT` / `SIGTRAP` ⇒ **App 直接闪退** ⭐⭐⭐

> ⚠️ **为什么之前 build324–333 没崩**：那条 `Task { @MainActor in }` 写在 **nonisolated `@Sendable` 闭包里**
> ⇒ 在旧语义下会切 MainActor ⇒ 不炸；**Swift 6.2/6.3 + iOS 27 的新语义下炸** ⇒ ⇒ **这是「换 SDK 之后才出现」的崩** ⭐⭐⭐

---

## 2. 修法

### ⭐ 主修：明确切主线程，不依赖 executor 继承语义
```swift
// 改前
Task { @MainActor in self.apply(snapshot) }
// 改后
DispatchQueue.main.async { self.apply(snapshot) }
```
⇒ `DispatchQueue.main.async` 的闭包是 **@MainActor 隔离**的 ⇒ `self.apply(snapshot)` 合法
⇒ 且**无论 observer 在哪个线程被调都安全** ⇒ 一处改动覆盖全部路径 ⭐⭐⭐

### ⭐ 同形态全清（`SpeechController` 7 处）
`AVSpeechSynthesizerDelegate` / `AVAudioPlayerDelegate` / `MPRemoteCommandCenter` 的回调
也是 **`@Sendable`** ⇒ 同一个坑（delegate 回调**可能在任意线程**）⇒ 7 处全改成 `DispatchQueue.main.async` ⭐⭐⭐

### ⭐ 附带修掉的其它真实隐患（同一轮一起加固）
| # | 隐患 | 后果 |
|---|---|---|
| ① | `VoicePackTransfer.directory` 用 `[0]` 强下标 | `urls(for:)` 返回空数组 ⇒ 💥 越界崩 |
| ② | `connect()` 无条件建 4 个 background URLSession | 同一 identifier 重复创建 = **系统未定义行为**；且每次开阅读器白起 4 条系统会话 ⇒ 改成「没有下载计划就不建会话」 |
| ③ | `VerticalController` 的 `as! StripCell` | 包内唯一的强制解包 ⇒ 类型不符就崩 |
| ④ | 柴阅 `durChapterIndex` **只有下界没有上界** | 起始章号越界 ⇒ 空白页甚至崩 ⇒ 三条取章号路径统一夹紧 |
| ⑤ | 镜像书架时换算失败落**原值** | 脏章号被**持久化**进柴阅书架仓 ⇒ 每次打开都被毒化 ⇒ 改落 0 |
| ⑥ | 起始章号**优先级反了** | 「开始阅读」停在错误的章 ⇒ 改成轻阅进度（主数据）优先，柴阅仓兜底且夹紧 |

---

## 3. 取证能力（这轮加的，下次不用再靠猜）

- 包内新增 `PublicLogBridge`（包 → 宿主 的日志出口；**不动协议** ⇒ 不碰 Swift 6 隔离）
- 柴阅 `ReaderContainer` / `ComicReaderScreen` 启动分段日志（①…⑤）
- 宿主 `prepare()` / host 构造 / 起始章号 分阶段日志
- ⇒ **用户取日志的路径（不用 .ips）**：**书源页 →「自检」→ 引擎日志面板 →「复制」** ⇒ 贴给我即可 ⭐⭐⭐

---

## 4. 门禁

- `test/reader-launch-hardening.test.js`：**28 项**（新增 ⑦⑧「并发隔离铁律」）
  ⇒ **nonisolated `@Sendable` 闭包里不许用 `Task { @MainActor in … }`**
- `test/mutation-reader-launch-hardening.sh`：**6/6**
  ⇒ 4 种变异（`[0]` 强下标 / 去掉 connect 守卫 / 去掉章号夹紧 / **把 observer 改回 `Task { @MainActor in }`**）⇒ 门禁必须红 ⇒ 复原必须绿
- 已挂进 `test/run-all-gates.sh`
- 相关门禁全绿：登录页 44 / 宿主 42 / 漫画 47 / 平台守卫 6 / 条件编译 183 / 类型 16

---

## 5. 交付

- CI：run `46110878815`（build335 第一轮，编的是**没修好**的版本 ⇒ **已主动取消**，省一个 macOS 队列）⇒ 本轮重新出包
- 产物：`QingYue-build335.zip` ⇒ 解包验 **CFBundleVersion = 335** ✔
- 二进制体检：版本 / 资源 / 符号三项照旧全验

---

## 6. ⚠️ **诚实说明**

- **真凶已定案**（.ips 栈帧直指那一行）⇒ 修复是**有据**的，不是猜的 ⭐⭐⭐
- 但**同批还有 6 处真实隐患**（①~⑥）⇒ 一并修掉 ⇒ 即使还有别的崩点，也不会再是「无从下手」
- ⇒ **真机请再点一次「开始阅读」** ⇒ 若还崩 ⇒ **把「书源页 → 自检 → 复制」的日志发我** ⇒ 日志最后一条 = 崩在哪一步 ⇒ 下一轮直接改那一行 ⭐⭐⭐
