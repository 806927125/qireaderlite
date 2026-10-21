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
  "login-status:test/login-status.test.js"
  "engine-lint:test/engine-lint.test.js"
  "engine-smoke:test/engine-smoke.test.js"
  "login-card:test/live-login-card.test.js"
  "toc-diag-truth:test/toc-diag-truth.test.js"
  "b64-url-mangle:test/b64-url-mangle.test.js"
  "qiyue-parity:test/qiyue-parity.test.js"
  "analyze-url-parity:test/analyze-url-parity.test.js"
  "fq-login:test/live-fq-login.test.js"
  "live-explore:test/live-explore.test.js"
  "live-toc:test/live-toc.test.js"
  "live-bookinfo:test/live-bookinfo.test.js"
  "reader-settings:test/reader-settings.test.js"
  "reader-native-paging:test/reader-native-paging.test.js"
  "reader-pageturn:test/reader-pageturn.test.js"
  "reader-jsapi:test/reader-jsapi.test.js"
  "native-bridge:test/native-bridge.test.js"
  "jsoup-xpath:test/jsoup-xpath.test.js"
  "engine-api-parity:test/engine-api-parity.test.js"
  "engine-java-api:test/engine-java-api.test.js"
  "engine-packages:test/engine-packages.test.js"
  "packages-native:test/packages-native.test.js"
  "packages-source:test/packages-source.test.js"
  "engine-script-toplevel:test/engine-script-toplevel.test.js"
  "dahulang-adapt:test/dahulang-adapt.test.js"
  "mfzs:test/mfzs.test.js"
  "pack125-adapt:test/pack125-adapt.test.js"
  "powenxue:test/powenxue.test.js"
  "paging-algorithm:test/paging-algorithm.test.js"
  "rules:test/rules.test.js"
  "e2e:test/e2e.test.js"
  "swift-bookdto:test/swift-bookdto.test.js"
)

TOTAL_PASS=0
TOTAL_FAIL=0
CRASHED=()
NOSUMMARY=()
FAILED=()

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
      printf "%-24s %-22s %s\n" "$name" "⏭ 跳过" "缺本机依赖文件"
    else
      printf "%-24s %-22s %s\n" "$name" "⚠️ 无汇总" "疑似提前退出"
      TOTAL_FAIL=$((TOTAL_FAIL+1))
      NOSUMMARY+=("$name")
    fi
    continue
  fi

  TOTAL_PASS=$((TOTAL_PASS + p))
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
if [ -x "/tmp/swift/usr/bin/swiftc" ] || command -v swiftc >/dev/null 2>&1; then
  if bash test/run-swift-tests.sh > /tmp/swift-tests.out 2>&1; then
    printf "%-24s %-22s %s\n" "swift 原生层" "✅" "$(grep -oE '通过 [0-9]+ / 失败 [0-9]+' /tmp/swift-tests.out | tail -1)"
    SWIFT_PASS="$(grep -oE '通过 [0-9]+' /tmp/swift-tests.out | tail -1 | grep -oE '[0-9]+')"
    TOTAL_PASS=$((TOTAL_PASS + ${SWIFT_PASS:-0}))
  else
    printf "%-24s %-22s %s\n" "swift 原生层" "❌ 有失败" "$(grep -oE '通过 [0-9]+ / 失败 [0-9]+' /tmp/swift-tests.out | tail -1)"
    grep -E "✗|error:" /tmp/swift-tests.out | head -5
    TOTAL_FAIL=$((TOTAL_FAIL+1))
    FAILED+=("swift-原生层")
  fi
else
  printf "%-24s %-22s %s\n" "swift 原生层" "⚠️ 跳过" "没装 swiftc"
fi

printf "%s\n" "────────────────────────────────────────────────────"
printf "合计通过 %d 项 / 失败 %d 个门禁\n" "$TOTAL_PASS" "$TOTAL_FAIL"


if [ ${#CRASHED[@]} -gt 0 ]; then
  printf "💥 崩了：%s\n" "${CRASHED[*]}"
fi
if [ ${#NOSUMMARY[@]} -gt 0 ]; then
  printf "⚠️ 无汇总行（疑似提前退出）：%s\n" "${NOSUMMARY[*]}"
fi
if [ ${#FAILED[@]} -gt 0 ]; then
  printf "❌ 有失败：%s\n" "${FAILED[*]}"
fi

# 门禁全绿 → 才算全绿
if [ "$TOTAL_FAIL" -eq 0 ]; then
  echo "✅ 门禁全绿"
  exit 0
else
  echo "❌ 门禁没过"
  exit 1
fi
