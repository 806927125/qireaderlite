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


