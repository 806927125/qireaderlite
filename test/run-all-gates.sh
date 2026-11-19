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
  # ⭐⭐⭐⭐⭐ **引擎替换契约**（2026-11-19：老的两条引擎全删 ⇒ 换成 `LegadoEngine`）
  #   ⇒ 钉住：老引擎痕迹为零 · 新引擎在位 · op 接线齐全 · 变量契约不丢 · 新引擎自带测试绿
  "engine-replacement-contract:test/engine-replacement-contract.test.js"
  "engine-package-deps:test/engine-package-deps.test.js"
  "engine-apple-api:test/engine-apple-api.test.js"
  # ⭐⭐⭐⭐⭐ **变异对照**（2026-11-19 实证）：证明上面那条门禁**可证伪**
  #   ⇒ 上一版门禁**断言了错误结论** ⇒ 门禁一直绿 + CI 一直红 ⇒ 两个都对不了 ⭐⭐⭐
  #   ⇒ 变异＝把实现改坏 ⇒ 门禁**必须红** ⇒ 否则那条断言就是摆设 ⭐⭐⭐
  "engine-apple-api-mutation:test/engine-apple-api.mutation.test.js"
  # ⭐⭐⭐⭐⭐ **App 侧类型撞名 / 引用不存在的类型**（2026-11-19 CI build296 实证）
  #   ⇒ `EngineLogPanel.swift` 里的类被错命名成 `EngineLog` ⇒ 和 `EngineLog.swift` 的 enum 撞名
  #      ⇒ 满屏「cannot find 'EngineLogPanel'」⇒ **沙盒完全看不见**（那个文件 import UIKit ⇒ 只留了 stub）⭐⭐⭐
  #   ⇒ 现在静态扫全工程源码 ⇒ 撞名 / 引用不存在的 `X.shared` **3 秒就抓** ⭐⭐⭐
  "app-type-sanity:test/app-type-sanity.test.js"
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
  #   ⇒ 本门禁钉死：① 灌进 `variable` ② 读回走 `collectStationVariable` ③ 两格不许混 ⭐⭐⭐
  "station-var-channel:test/station-var-channel.test.js"
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
  "workflow-yaml-gate:test/workflow-yaml-gate.test.js"
  "explore-kinds-parity:test/explore-kinds-parity.test.js"
  "explore-paging-glass:test/explore-paging-glass.test.js"
  "source-test:test/source-test.test.js"
  "reader-settings:test/reader-settings.test.js"
  "reader-native-paging:test/reader-native-paging.test.js"
  "reader-pageturn:test/reader-pageturn.test.js"
  "reader-jsapi:test/reader-jsapi.test.js"
  "paging-algorithm:test/paging-algorithm.test.js"
  # ⭐⭐⭐ **主线程门禁**（2026-10-25 真机闪退）：非 @MainActor 的函数碰 UIKit ⇒ 后台线程调到就崩
  "mainactor-ui-guard:test/mainactor-ui-guard.test.js"
  "real-timeout-guard:test/real-timeout-guard.test.js"
  # ⭐⭐⭐⭐⭐ **Linux 编译门禁**（改了 Core/ 沙盒却全绿 ⇒ 因为它**根本没被编过**）
  #   ⇒ 现在 swiftc 真编 + **链真引擎** ⇒ 3 秒抓到 ⇒ 不用等 5 分钟 CI
  "linux-compile:test/linux-compile-gate.test.js"
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


