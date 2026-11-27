#!/usr/bin/env bash
# ============================================================
# 轻阅 Lite 全量门禁
#
# 跑法：bash test/run-all-gates.sh
#
# ⚠️⚠️ 这个脚本存在的理由：**崩了的门禁不产汇总行**。
#
#   以前每次都只 grep「通过 N / 失败 M」这一行 →
#   崩了的文件没有汇总行 → **输出为空** → 被当成「没问题」→ 假绿。
#   实测：reader-settings 从 build133 到 build142 一直是崩的，
#   假绿了 10 个 build 都没人发现（崩在第 608 行的 ReferenceError）。
#
#   所以这里的顺序是**先判崩溃，再读汇总行**：
#     ① 跑
#     ② 输出里有 ReferenceError / SyntaxError / ENOENT / Error: → 判「崩」
#     ③ 崩了 → 算失败（哪怕没有汇总行）
#     ④ 没崩但**没有汇总行** → 也算失败（可疑：可能提前 return 了）
#     ⑤ 最后才读汇总行
# ============================================================
set -uo pipefail
cd "$(dirname "$0")/.."

# 有些门禁依赖本机文件（书源 JSON），没有就自己跳过 —— 那是「跳过」不是「通过」
declare -a GATES=(
  "engine-package-deps:test/engine-package-deps.test.js"
  "engine-apple-api:test/engine-apple-api.test.js"
  # ⭐⭐⭐⭐⭐ **变异对照**（2026-11-19 实证）：证明上面那条门禁**可证伪**
  #   ⇒ 上一版门禁**断言了错误结论** ⇒ 门禁一直绿 + CI 一直红 ⇒ 两个都对不了 ⭐⭐⭐
  #   ⇒ 变异＝把实现改坏 ⇒ 门禁**必须红** ⇒ 否则那条断言就是摆设 ⭐⭐⭐
  # ⚠️ **engine-apple-api-mutation 已删**（2026-11-21）：变异全针对**旧引擎**的 `Crypto.swift`
  #   （compression_stream / CCPadding…）⇒ 旧引擎已换成柴阅 ⇒ **前提消失** ⭐⭐⭐
  # ⭐⭐⭐⭐⭐ **App 侧类型撞名 / 引用不存在的类型**（2026-11-19 CI build296 实证）
  #   ⇒ `EngineLogPanel.swift` 里的类被错命名成 `EngineLog` ⇒ 和 `EngineLog.swift` 的 enum 撞名
  #      ⇒ 满屏「cannot find 'EngineLogPanel'」⇒ **沙盒完全看不见**（那个文件 import UIKit ⇒ 只留了 stub）⭐⭐⭐
  #   ⇒ 现在静态扫全工程源码 ⇒ 撞名 / 引用不存在的 `X.shared` **3 秒就抓** ⭐⭐⭐
  "app-type-sanity:test/app-type-sanity.test.js"
  # ⭐⭐⭐⭐⭐ **loginHeader 槽的归属**（2026-11-24 真机「Token 格式错误」真凶）⭐⭐⭐⭐⭐
  #   ⇒ 站方的 token 与宿主的「Cookie: sessionid=…」（番茄兜底）**抢同一个槽**⭐⭐⭐
  #   ⇒ ⇒ 番茄那次写把 token 冲掉 ⇒ ⇒ 站方解不出 base64 ⇒ ⇒ 回「Token 格式错误」⭐⭐⭐
  #   ⇒ 现在：**番茄兜底不再写那个槽** + 每个 op **自愈**清掉宿主旧格式 ⭐⭐⭐
  #   ⇒ 且 cookie 快照**真被引擎吃掉**（站方 `cookie.getCookie(...)` 才有值）⭐⭐⭐
  "login-header-slot:test/login-header-slot.test.js"
  # ⭐⭐⭐⭐⭐ **书山适配版的改名隔离必须【完整】且【可复现】**（2026-11-24 真机「切平台无效」实证）⭐⭐⭐⭐⭐
  #   ⇒ 站方的筛选 action 是**字符串** ⇒ 改名（按 AST 改）**漏掉了里面的调用** ⭐⭐⭐
  #   ⇒ 引擎里符号未定义 ⇒ ReferenceError ⇒ **筛选静默失效**（切到 QQ 阅读，分类还在番茄）⭐⭐⭐
  #   ⇒ 门禁①：适配版必须能由脚本从原源**原样重新生成**（手改也会被抓到）⭐⭐⭐
  #   ⇒ 门禁②：适配版里不许残留「旧名调用点」（判据是**调用点**，URL 里的名字不算）⭐⭐⭐
  "shushan-rename-calls:test/shushan-rename-call-sites.test.js"
  # ⭐⭐⭐⭐⭐ **「星澜终端」皮肤的约定**（2026-11-24 用户给 HTML 原型后换肤）⭐⭐⭐⭐⭐
  #   ⇒ ① 换肤只改 Theme/Terminal 一处（页面里不许硬编码颜色 ⇒ 不会漂）⭐⭐⭐
  #   ⇒ ② ⭐⭐⭐⭐⭐ **发现页的筛选键必须保留**（用户明确要求！）⭐⭐⭐⭐⭐
  #      （筛选键 = 切平台/性别/模式的唯一入口 ⇒ 弄没了用户又会遇到「切了没反应」）⭐⭐⭐
  #   ⇒ ③ 玻璃白纱默认必须是「通透」而不是「乳白」（深色底上 38% 白纱会糊成一片白）⭐⭐⭐
  "terminal-theme:test/terminal-theme.test.js"
  # ⭐⭐⭐⭐⭐ **正文阅读页的「柴阅皮肤」**（2026-11-25 用户：「我要全搬柴阅的」）⭐⭐⭐⭐⭐
  #   ⇒ 四套皮肤（宣纸/晴窗/星夜/烛灯）+ 一页的页眉页脚 + 章节号装饰 + 排版默认值 ⭐⭐⭐
  "reader-skin-chaiyue:test/reader-skin-chaiyue.test.js"
  # ⭐⭐⭐⭐⭐ **沙盒语法门禁**（2026-11-25 build322 实证：括号剥错 ⇒ 烧了一轮 CI）⭐⭐⭐⭐⭐
  #   ⇒ `swiftc -parse` **只查语法**（不需要 SwiftUI/UIKit）⇒ Linux 沙盒就能查全量 App 源码 ⭐⭐⭐
  #   ⇒ 15 秒扫 67 个文件 ⇒ **语法错不再跑到 CI 才发现** ⭐⭐⭐
  #   ⚠️ 它**抓不到类型错** ⇒ CI 仍然要跑（那是唯一能验类型的东西）⭐⭐⭐
  #   ⚠️ **必须用 `.test.js` 包一层**：runner 是 `node "$file"` ⇒ `.sh` 会被当 JS 解析 ⭐⭐⭐
  "syntax-parse:test/syntax-parse-gate.test.js"
  # ⭐⭐⭐⭐⭐ **站方 exploreUrl 的分类归一化：旧引擎 JS ⇔ 新 Swift 双实现对拍**
  #   （2026-11-19 真机 build296 实证：换装新引擎丢了「先求值 @js: 的 exploreUrl」⇒ 分类 url 为空
  #     ⇒ `url 解析失败: ` ⇒ LegadoError 错误 1 ⇒ **发现页整个用不了**⭐⭐⭐）
  #   ⇒ oracle = git 里**已删的旧引擎**（0b5c481^）的 normalizeKinds/filterParamKey/absolutize
  #   ⇒ 新 Swift 实现（App 真文件）必须**逐字段一致** ⇒ 抄歪了立刻红 ⭐⭐⭐
  # ⭐⭐⭐⭐⭐ **workflow YAML 合法性**（2026-11-19 CI run 468 实证）
  #   ⇒ step name 里写了裸 `@js:` ⇒ **`@` 是 YAML 保留指示符** ⇒ **整个 workflow 解析失败** ⭐⭐⭐
  #   ⇒ 症状 = **CI 立刻失败、且一个 job 都没有**（`jobs: []`）⇒ 什么都看不见 ⇒ 最难查的一类 ⭐⭐⭐
  #   ⇒ 本地 3 秒 parse 一遍 ⇒ 当场报「哪个文件哪一行」⭐⭐⭐
  # ⭐⭐⭐⭐⭐ **站方变量通道**（2026-11-19 真机 build297 实证）
  #   ⇒ 真机：发现页从「LegadoError 1」变成「只解析出 0 个分类」⇒ **求值通了、站方交白卷**⭐⭐⭐
  #   ⇒ 根因 = 引擎的 `srcGet` 读 `BookSource.variable` 那一格，而 App 灌的是 `__variable`（**另一格**）
  #     ⇒ 站方 JS 读 `source.get("nhAuthed")` 恒空 ⇒ `nhAuth()` 恒 false ⇒ **主动交白卷**⭐⭐⭐
  #   ⇒ ⚠️ **本条已换**：宿主不再灌/回传变量（柴阅自己持久化）⇒ 改由 `chaiyue-port-contract` 钉 ⭐⭐⭐
  # ⭐⭐⭐⭐⭐ **Apple-only 块的类型错**（2026-11-19 CI build300 实证）
  #   ⇒ 那段代码在 `#if canImport(JavaScriptCore) && !os(Linux)` 里 ⇒ **Linux 沙盒门禁编不到** ⭐⭐⭐
  #   ⇒ 我把方法加在【嵌套的 Session】里、调用点却写 `Self.` ⇒ Apple 平台编译失败 ⭐⭐⭐
  #   ⇒ 静态扫 `Self.<方法>` 的作用域归属 ⇒ **3 秒抓**（不用等 CI 5 分钟）⭐⭐⭐
  "apple-only-typecheck:test/apple-only-typecheck.test.js"
  # ⭐⭐⭐⭐⭐ **「0 个分类」的诊断提示必须【有依据】**（2026-11-19 真机双源对照，用户直接指出「你弄反了」）
  #   ⇒ 🍅大灰狼（**没有** nhAuth 门禁）被误报成「多半是门禁没解锁」⭐⭐⭐
  #   ⇒ 而 🍒NovelHub（**真有**门禁）反而没说（因为查错了槽）⭐⭐⭐
  #   ⇒ 现在：① 依据【源自己的 jsLib】判有没有门禁 ② 解锁态查【两个】槽 ⭐⭐⭐
  "explore-diagnose-hint:test/explore-diagnose-hint.test.js"
  # ⭐⭐⭐⭐⭐ **整源密码门禁的整链复现**（①表单值→loginInfo→②unlockAll→③落槽→④灌引擎→⑤合并→⑥nhAuth 放行）⭐⭐⭐
  #   ⇒ 每环【真跑】（用产物 jsLib 里抽出的站方真身）⇒ 断在哪一环一目了然 ⭐⭐⭐
  "auth-gate-chain:test/auth-gate-chain.test.js"
  # ⭐⭐⭐⭐⭐ **柴阅移植契约**（2026-11-21）⭐⭐⭐
  #   ⇒ 钉死：包结构 / 柴阅两套语义 / 宿主走 WebBook / 不再回传变量 / store 映射 / kinds 适配 ⭐⭐⭐
  "chaiyue-port-contract:test/chaiyue-port-contract.test.js"
  # ⭐⭐⭐⭐⭐ **发现页筛选栏的「选中 ⇒ 生效」整条链**（2026-11-21 真机「筛选键没用」实证）⭐⭐⭐
  #   ⇒ 三个静默断点：① infoMap 没传 ② 柴阅 exploreKinds 命中缓存 ③ App 侧 kindsCache 不失效 ⭐⭐⭐
  "filter-action-wiring:test/filter-action-wiring.test.js"
  # ⭐⭐⭐⭐⭐ **筛选变量的【写入 ⇒ 站方读回】必须【真跑】**（2026-11-21 真机「筛选键没用」二次实证）⭐⭐⭐
  #   ⇒ 上一轮只补了 `infoMap` ⇒ 没生效 ⇒ 因为 UI 走的是「轻阅自己写 paramKey」那条路 ⭐⭐⭐
  #   ⇒ 而站方 exploreUrl 读的是站方变量整串里的 **`src`** ⇒ 轻阅写的 `find_source` **它不读** ⭐⭐⭐
  #   ⇒ 本门禁用 **swiftc 编 App 的真文件** 真跑一遍「写入 → 站方读回」⇒ 门禁变红 ⇒ App 一定有问题 ⭐⭐⭐
  "filter-var-roundtrip:test/filter-var-roundtrip.test.js"
  # ⭐⭐⭐⭐⭐ **登录面板的「行」必须能求值出来**（2026-11-21 真机「登录界面没按钮」实证）⭐⭐⭐
  #   ⇒ 站方 loginUi 常是 `@js:` 薄壳 ⇒ 静态解析失败 ⇒ 面板空白 ⇒ **一个按钮都没有** ⭐⭐⭐
  #   ⇒ 柴阅的 `resolveLoginRows` 会求值它 ⇒ 行拿得到（★ 真跑探针在 CI 上验）⭐⭐⭐
  "login-rows-wiring:test/login-rows-wiring.test.js"
  # ⭐⭐⭐⭐⭐ **登录配套设施（柴阅 ReaderPlatform）必须真的接上**（2026-11-21 移植）⭐⭐⭐
  #   ⇒ 柴阅把「浏览器/验证码/后台渲染/toast」交给宿主 ⇒ 轻阅之前**没实现** ⇒ **静默失败** ⭐⭐⭐
  #   ⇒ 聚合源的「🍅番茄登录 / 🔐注册书源 / 🏝用户后台」全是浏览器流程 ⇒ 浏览器不工作 ⇒ **登录永远失败** ⭐⭐⭐
  "login-platform-wiring:test/login-platform-wiring.test.js"
  # ⭐⭐⭐⭐⭐ **explore 的「0 本」必须能【定责】**（2026-11-21 真机「书单 0 本」实证）⭐⭐⭐
  #   ⇒ 以前只有一句「书单 0 本」⇒ 分不清「站方没数据 / 规则没匹配上 / URL 错了」⭐⭐⭐
  #   ⇒ 现在：引擎在**同一次请求**里带回诊断 ⇒ UI 的提示**带原因** ⇒ 一眼定责 ⭐⭐⭐
  "explore-diag-attribution:test/explore-diag-attribution.test.js"
  # ⭐⭐⭐⭐⭐ **条件编译块的 import 完整性**（2026-11-21 移植柴阅的真实事故）⭐⭐⭐
  #   ⇒ 柴阅的 `Digests` 拆文件时漏了 `import CommonCrypto` ⇒ **Linux 沙盒编不到** ⭐⭐⭐
  #   ⇒ 沙盒门禁全绿 ⇒ 直到 CI 才报「cannot find 'CC_SHA224' in scope」⭐⭐⭐
  #   ⇒ 正解：**静态扫**（用了某框架的符号 ⇒ 该文件必须 import 它）⇒ Apple-only 错误也能在沙盒抓 ⭐⭐⭐
  "conditional-import-gate:test/conditional-import-gate.test.js"
  "workflow-yaml-gate:test/workflow-yaml-gate.test.js"
  # ⚠️ **explore-kinds-parity 已删**（2026-11-21）：它是【旧引擎 normalizeKinds 的 oracle 对拍】⭐⭐⭐
  #   ⇒ 旧引擎已换成柴阅 ⇒ **对拍对象不存在了** ⇒ 前提消失 ⇒ 删 ⭐⭐⭐
  #   ⇒ 覆盖改由：① 柴阅自带的权威测试（CI 上跑）② `chaiyue-port-contract` 钉契约 ⭐⭐⭐
  "explore-paging-glass:test/explore-paging-glass.test.js"
  "source-test:test/source-test.test.js"
  "reader-settings:test/reader-settings.test.js"
  "reader-api-surface:test/reader-api-surface.test.js"
  # ⭐⭐⭐⭐⭐ **正文阅读界面 = 柴阅那套**（2026-11-25 接柴阅阅读器）⭐⭐⭐⭐⭐
  #   ⇒ 老阅读器（我们自研的原生分页 / 滚动 / WebView）**整套删掉** ⇒ 正文界面全部用柴阅的 ⭐⭐⭐
  #   ⇒ 这条门禁是**双向**的：① 老阅读器符号 0 命中 ② 柴阅阅读器必须在 ③ 门禁能红（变异对照）⭐⭐⭐
  # ⭐⭐⭐⭐⭐ **老引擎的残留不许回来**（2026-11-26 用户「把老的引擎代码全删了，只留柴阅的」）⭐⭐⭐⭐⭐
  #   已删：`LegadoEngine/Reference/`（老引擎 LegadoR 的逆向产物）+ 老引擎的 README
  #   ⇒ 门禁钉住「删干净」这件事 ⇒ 下次谁把老东西拷回来，门禁立刻红 ⭐⭐⭐
  "engine-no-legacy:test/engine-no-legacy.test.js"
  # ⭐⭐⭐⭐⭐ **浏览器/验证码必须浮在【阅读器】之上**（2026-11-27 真机「段评要先回详情页」）⭐⭐⭐⭐⭐
  #   根 View 的 sheet 被 fullScreenCover（阅读器）压住 ⇒ 浏览器看不见 ⇒ 必须由阅读器那层承载
  "browser-on-reader:test/browser-on-reader.test.js"
  # ⭐⭐⭐⭐⭐ **柴阅阅读器的【平台守卫】必须自洽**（2026-11-26 CI333c 实锤）⭐⭐⭐⭐⭐
  #   `LegadoEngine` 依赖 `ChaiyueReader` ⇒ macOS/Linux 上也编该模块 ⇒
  #   ⇒ 暴露「无守卫文件引用了有守卫文件里的类型」⇒ iOS 界面层平时看不见 ⇒ 只有静态扫描能提前抓
  "reader-platform-guards:test/reader-platform-guards.test.js"
  "reader-chaiyue-host:test/reader-chaiyue-host.test.js"
  # ⭐⭐⭐⭐⭐ **柴阅的【图标资源】与【外观切换】必须真的能用**（2026-11-26 真机反馈）⭐⭐⭐⭐⭐
  #   ① 悬浮栏图标全没了 / 主题小页纸糊了 ⇒ 柴阅图标是**自绘资源**（`cy.*.symbolset` + `Theme-*`）
  #      ⇒ 只搬 Swift 源码、没搬资源 ⇒ 那个图标就空白 ⇒ 门禁钉「资源与 IconNames 一一对应」
  #   ② 日/夜切不动、③ 浅色主题切不动 ⇒ 根因同一个：轻阅根部强制深色 vs 柴阅的外观切换**打架**
  #      ⇒ 门禁钉「apply() 不改窗口」+「宿主阅读器施加 preferredColorScheme」
  "reader-chaiyue-assets-appearance:test/reader-chaiyue-assets-appearance.test.js"
  # ⭐⭐⭐⭐⭐ **柴阅的【内置主题包】**（2026-11-26 用户拍板「要」）⭐⭐⭐⭐⭐
  #   7 个 .chaiyuetheme（11 MB）⇒ 柴阅上游自己没给「一键装」的界面 ⇒ 轻阅新增这一栏
  #   ⇒ 门禁钉「包在 / 找得到 / 装得进 / 点得着」四条，缺一条这功能就是坏的
  "reader-chaiyue-preset-themes:test/reader-chaiyue-preset-themes.test.js"
  # ⭐⭐⭐⭐⭐ **柴阅的【漫画阅读器】**（2026-11-26 用户「把漫画阅读器也搬过来」）⭐⭐⭐⭐⭐
  #   漫画的图 = 章节正文里的 <img> ⇒ 数据链本来就通；缺的是界面层 + 「站方 book.type 被丢掉」这个断点
  #   ⇒ 门禁钉「文件在 / 宿主能开 / 启动通道 / 会话能造 / type 不丢 / 详情页分流」六条
  "reader-chaiyue-comic:test/reader-chaiyue-comic.test.js"
  "reader-pageturn:test/reader-pageturn.test.js"
  # ⚠️⚠️ **reader-native-paging / paging-algorithm 已删**（2026-11-25）⭐⭐⭐
  #   ⇒ 它们钉的是**我们自己那套**分页器（`ReaderPaginator` / `PagedChapterPager`）⭐⭐⭐
  #   ⇒ 那套实现整套删掉了 ⇒ 门禁的前提消失 ⇒ 删（不是放宽）⭐⭐⭐
  #   ⇒ 翻页/排版的覆盖改由：① 柴阅包侧的权威实现 ② `reader-pageturn` + `reader-skin-chaiyue` 钉契约 ⭐⭐⭐
  # ⭐⭐⭐ **主线程门禁**（2026-10-25 真机闪退）：非 @MainActor 的函数碰 UIKit ⇒ 后台线程调到就崩
  "mainactor-ui-guard:test/mainactor-ui-guard.test.js"
  "real-timeout-guard:test/real-timeout-guard.test.js"
  # ⭐⭐⭐⭐⭐ **Linux 编译门禁**（改了 Core/ 沙盒却全绿 ⇒ 因为它**根本没被编过**）
  #   ⇒ 现在 swiftc 真编 + **链真引擎** ⇒ 3 秒抓到 ⇒ 不用等 5 分钟 CI
  "linux-compile:test/linux-compile-gate.test.js"
  # ⭐⭐⭐⭐⭐ **书山聚合适配门禁**（2026-11-23）
  #   ⇒ 钉死「顶层符号隔离化」的 7 条断言（引用计数守恒 / 幂等 / 非 JS 字段未误改 …）⭐⭐⭐
  #   ⇒ 探针（真引擎真跑）在 **CI（macOS）** 上跑 ⇒ 这里只守**静态**性质 ⭐⭐⭐
  "shushan-adapt:test/shushan-adapt.test.js"
)
TOTAL_PASS=0
TOTAL_FAIL=0
CRASHED=()
NOSUMMARY=()
FAILED=()
SKIPPED=()

printf "%-24s %-22s %s\n" "门禁" "结果" "备注"
printf "%s\n" "────────────────────────────────────────────────────"

for entry in "${GATES[@]}"; do
  name="${entry%%:*}"
  file="${entry#*:}"
  if [ ! -f "$file" ]; then
    printf "%-24s %-22s %s\n" "$name" "缺文件" "$file"
    TOTAL_FAIL=$((TOTAL_FAIL+1))
    FAILED+=("$name")
    continue
  fi

  # 活体测试（打真服务器）会偶发抖动 → 失败重试一次再判
  out="$(node "$file" 2>&1)"
  rc=$?
  case "$name" in
    live-*|fq-login)
      if [ "$rc" -ne 0 ]; then
        sleep 5
        out="$(node "$file" 2>&1)"
        rc=$?
      fi
      ;;
  esac

  # ① 先判崩溃（崩了就不会有汇总行）
  #    ⚠️ 不能拿 "Error" 裸匹配 —— 测试用例名里就有「→ Error」这种字样
  #    （jsoup-xpath 的 '[xpath] $$$$ → Error'），会把好门禁误判成崩了。
  #    只认**真异常**的样子：xxxError: / 行首 Error: / ENOENT:
  crash="$(printf '%s' "$out" \
    | grep -oE '(ReferenceError|SyntaxError|TypeError|RangeError|ENOENT|Cannot find module)[^\\n]{0,80}' \
    | head -1)"
  if [ -z "$crash" ]; then
    crash="$(printf '%s' "$out" | grep -oE '^[[:space:]]*Error:[^\\n]{0,80}' | head -1 | sed 's/^[[:space:]]*//')"
  fi
  if [ -n "$crash" ]; then
    printf "%-24s %-22s %s\n" "$name" "💥 崩了" "$(printf '%s' "$crash" | cut -c1-60)"
    TOTAL_FAIL=$((TOTAL_FAIL+1))
    CRASHED+=("$name")
    continue
  fi

  # ② 读汇总行
  #    格式有好几种，统一认「通过数」和「失败数」这一对：
  #       通过 48 / 失败 0        （jsoup-xpath 等）
  #       37 通过 / 0 失败        （e2e / rules）
  #       通过 20 失败 0          （engine-packages 等）
  read -r p f <<< "$(printf '%s' "$out" | python3 test/parse-summary.py)"

  if [ -z "${p:-}" ]; then
    # ③ 没有汇总行 → 可疑，不算通过
    skipped="$(printf '%s' "$out" | grep -c '跳过\|skip' || true)"
    if [ "$skipped" -gt 0 ]; then
      printf "%-24s %-22s %s\n" "$name" "⏭ 跳过" "没有汇总行（站方抖动/缺本机依赖）"
      SKIPPED+=("$name")
    else
      printf "%-24s %-22s %s\n" "$name" "⚠️ 无汇总" "疑似提前退出"
      TOTAL_FAIL=$((TOTAL_FAIL+1))
      NOSUMMARY+=("$name")
    fi
    continue
  fi

  TOTAL_PASS=$((TOTAL_PASS + p))
  # ⭐⭐⭐ **「通过 0 项」= 门禁在演戏**（2026-10-24 真机教训）
  #   一条断言都没跑 ⇒ 它什么都没验 ⇒ 却显示成 ✅ ⇒ **假绿**
  #   （真机炸出「登录界面没了 / 打开登录卡死」时，沙盒里好几个门禁正是 0 项通过 ⭐⭐⭐）
  #   ⇒ 现在：**0 项 ⇒ 判失败**（宁可红，也别假装验过）⭐
  #   ⚠️ **但要分清两种 0 项**：
  #     ① 门禁自己**明说**「站方限流/环境不行，本次跳过」⇒ 那是**环境跳过**（不算门禁坏）
  #     ② 一声不吭地 0 项 ⇒ 门禁坏了（断言被清空了 / 文件没跑到）⇒ **失败** ⭐
  if [ "$p" -eq 0 ] && [ "$f" -eq 0 ]; then
    if printf '%s' "$out" | grep -q '跳过\|skip'; then
      printf "%-24s %-22s %s\n" "$name" "⏭ 环境跳过" "0 项（门禁明说环境不行 ⇒ 没验到，不算通过）"
      SKIPPED+=("$name")
    else
      printf "%-24s %-22s %s\n" "$name" "⚠️ 空门禁" "通过 0 项（一条断言都没跑 ⇒ 没验到）"
      TOTAL_FAIL=$((TOTAL_FAIL+1))
      FAILED+=("$name")
    fi
    continue
  fi
  if [ "$f" -gt 0 ] || [ "$rc" -ne 0 ]; then
    printf "%-24s %-22s %s\n" "$name" "❌ 有失败" "通过 $p / 失败 $f"
    TOTAL_FAIL=$((TOTAL_FAIL+1))
    FAILED+=("$name")
  else
    printf "%-24s %-22s %s\n" "$name" "✅" "通过 $p / 失败 $f"
  fi
done

printf "%s\n" "────────────────────────────────────────────────────"

# ── 变异测试（shell 层）：⭐⭐⭐ **引擎替换契约**（2026-11-19）──
#   ⇒ 把新引擎接线的「变量回传 / op 接线 / SPM 依赖」改坏 ⇒ 门禁必须红（证明门禁有牙齿）⭐⭐⭐
#   ⇒ 变异脚本会**真的改源码** ⇒ 跑之前必须 commit（否则改坏的东西会留在工作区）⭐⭐⭐
if git diff --quiet -- QiReaderLite/ 2>/dev/null; then
  if bash test/mutation-engine-replacement.sh > /tmp/mutation-repl.out 2>&1; then
    printf "%-24s %-22s %s\n" "变异(引擎替换)" "✅" "$(grep -oE '通过 [0-9]+ / 失败 [0-9]+' /tmp/mutation-repl.out | tail -1)"
    MP="$(grep -oE '通过 [0-9]+' /tmp/mutation-repl.out | tail -1 | grep -oE '[0-9]+')"
    TOTAL_PASS=$((TOTAL_PASS + ${MP:-0}))
  else
    printf "%-24s %-22s %s\n" "变异(引擎替换)" "❌ 有失败" "$(grep -oE '通过 [0-9]+ / 失败 [0-9]+' /tmp/mutation-repl.out | tail -1)"
    grep -E "✗" /tmp/mutation-repl.out | head -5
    TOTAL_FAIL=$((TOTAL_FAIL+1))
    FAILED+=("变异(引擎替换)")
  fi
else
  printf "%-24s %-22s %s\n" "变异(引擎替换)" "⚠️ 跳过" "QiReaderLite/ 有未提交改动（变异脚本会改源码 ⇒ 先 commit）"
  SKIPPED+=("变异(引擎替换)")
fi

# ── 变异测试（shell 层）：⭐⭐⭐⭐⭐ **引擎包编译失败必须被抓住**（2026-11-24 build318 实证）──
#   ⇒ 原来的 `swift build … | tail -3` **把引擎的编译失败吞掉了**（管道退出码 = tail 的）⭐⭐⭐
#   ⇒ 门禁拿**旧 .swiftmodule** 继续编 App ⇒ **全绿** ⇒ ⇒ 我改的引擎文件**根本没被编过** ⭐⭐⭐
#   ⇒ ⇒ 同样的错只能等 CI 才发现（build318 就这么挂了一轮）⭐⭐⭐
#   ⇒ 本变异把引擎改坏 ⇒ 门禁**必须红** ⇒ 复原 ⇒ 必须绿 ⭐⭐⭐
if git diff --quiet -- LegadoEngine/ 2>/dev/null; then
  if bash test/mutation-engine-build-gate.sh > /tmp/mutation-engbuild.out 2>&1; then
    printf "%-24s %-22s %s\n" "变异(引擎编译)" "✅" "$(grep -oE '通过 [0-9]+ / 失败 [0-9]+' /tmp/mutation-engbuild.out | tail -1)"
    MP="$(grep -oE '通过 [0-9]+' /tmp/mutation-engbuild.out | tail -1 | grep -oE '[0-9]+')"
    TOTAL_PASS=$((TOTAL_PASS + ${MP:-0}))
  else
    printf "%-24s %-22s %s\n" "变异(引擎编译)" "❌ 有失败" "$(grep -oE '通过 [0-9]+ / 失败 [0-9]+' /tmp/mutation-engbuild.out | tail -1)"
    grep -E "✗" /tmp/mutation-engbuild.out | head -5
    TOTAL_FAIL=$((TOTAL_FAIL+1))
    FAILED+=("变异(引擎编译)")
  fi
else
  printf "%-24s %-22s %s\n" "变异(引擎编译)" "⚠️ 跳过" "LegadoEngine/ 有未提交改动（变异脚本会改源码 ⇒ 先 commit）"
  SKIPPED+=("变异(引擎编译)")
fi

# ── Swift 原生层：swiftc 真编真跑（Core/ 是纯 Foundation → 沙盒里能跑）──
# ⚠️ 这一步是「引擎能力用 Swift 写」能落地的**前提**：
#    能力写在 Swift 里，就得能在沙盒里验（3 秒出结果，不用等 CI）。
# ⚠️⚠️ **别在这里判断 swiftc 在不在**（2026-10-21 踩过）：
#    外层只认 `/tmp/swift/usr/bin/swiftc`，而沙盒**会把 /tmp 清掉**；
#    toolchain 装在 `<repo>/../.toolchain/swift` 时 ⇒ 外层判「没装」⇒ **直接跳过**
#    ⇒ run-swift-tests.sh 根本没被调用 ⇒ 报「全绿」但一行 Swift 都没编 ⭐
#    ⇒ 判断逻辑必须**只有一份** ⇒ 统一交给 run-swift-tests.sh，它自己会明确打印原因。
if bash test/run-swift-tests.sh > /tmp/swift-tests.out 2>&1; then
  if grep -q '没找到 swiftc' /tmp/swift-tests.out; then
    printf "%-24s %-22s %s\n" "swift 原生层" "⚠️ 跳过" "没装 swiftc（见 test/run-swift-tests.sh 里的安装提示）"
    SKIPPED+=("swift-原生层")
  else
    printf "%-24s %-22s %s\n" "swift 原生层" "✅" "$(grep -oE '通过 [0-9]+ / 失败 [0-9]+' /tmp/swift-tests.out | tail -1)"
    SWIFT_PASS="$(grep -oE '通过 [0-9]+' /tmp/swift-tests.out | tail -1 | grep -oE '[0-9]+')"
    TOTAL_PASS=$((TOTAL_PASS + ${SWIFT_PASS:-0}))
  fi
else
  printf "%-24s %-22s %s\n" "swift 原生层" "❌ 有失败" "$(grep -oE '通过 [0-9]+ / 失败 [0-9]+' /tmp/swift-tests.out | tail -1)"
  grep -E "✗|error:" /tmp/swift-tests.out | head -5
  TOTAL_FAIL=$((TOTAL_FAIL+1))
  FAILED+=("swift-原生层")
fi

printf "%s\n" "────────────────────────────────────────────────────"

# ── 变异测试（shell 层）：把实现改坏 ⇒ 门禁必须红 ──
# ⭐⭐⭐⭐⭐ 2026-10-29 新增：**凭据双写**（站方变量 ⇄ 书源变量 `token` 项）
#   ⇒ 变异脚本会**真的改源码** ⇒ 跑之前必须 commit（否则改坏的东西会留在工作区）⭐⭐⭐
if git diff --quiet -- QiReaderLite/ 2>/dev/null; then
  if bash test/mutation-credential-mirror.sh > /tmp/mutation-cred.out 2>&1; then
    printf "%-24s %-22s %s\n" "变异(凭据双写)" "✅" "$(grep -oE '通过 [0-9]+ / 失败 [0-9]+' /tmp/mutation-cred.out | tail -1)"
    MP="$(grep -oE '通过 [0-9]+' /tmp/mutation-cred.out | tail -1 | grep -oE '[0-9]+')"
    TOTAL_PASS=$((TOTAL_PASS + ${MP:-0}))
  else
    printf "%-24s %-22s %s\n" "变异(凭据双写)" "❌ 有失败" "$(grep -oE '通过 [0-9]+ / 失败 [0-9]+' /tmp/mutation-cred.out | tail -1)"
    grep -E "✗|COMPILE_ERROR" /tmp/mutation-cred.out | head -5
    TOTAL_FAIL=$((TOTAL_FAIL+1))
    FAILED+=("变异(凭据双写)")
  fi
else
  printf "%-24s %-22s %s\n" "变异(凭据双写)" "⚠️ 跳过" "QiReaderLite/ 有未提交改动（变异脚本会改源码 ⇒ 先 commit）"
  SKIPPED+=("变异(凭据双写)")
fi

printf "%s\n" "────────────────────────────────────────────────────"


