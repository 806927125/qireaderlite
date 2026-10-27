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
  "ajax-retry:test/ajax-retry.test.js"
  "ajax-candidate-group:test/ajax-candidate-group.test.js"
  "explore-filter:test/explore-filter.test.js"
  "host-failover:test/host-failover.test.js"
  "toc-placeholder:test/toc-placeholder.test.js"
  "global-isolation:test/global-isolation.test.js"
  "explore-paging-glass:test/explore-paging-glass.test.js"
  "explore-groups:test/explore-groups.test.js"
  "js-no-interpolate:test/js-no-interpolate.test.js"
  "login-formvalues:test/login-formvalues.test.js"
  "source-getput:test/source-getput.test.js"
  "js-booklist:test/js-booklist.test.js"
  "data-url-guard:test/data-url-guard.test.js"
  "global-restore:test/global-restore.test.js"
  "book-raw:test/book-raw.test.js"
  "js-no-tail:test/js-no-tail.test.js"
  "data-url-bookid:test/data-url-bookid.test.js"
  "result-semantics:test/result-semantics.test.js"
  "rule-syntax-compat:test/rule-syntax-compat.test.js"
  "swift-dto-tolerant:test/swift-dto-tolerant.test.js"
  "filter-action:test/filter-action.test.js"
  "source-test:test/source-test.test.js"
  "browser-sync:test/browser-sync.test.js"
  "timeout-budget:test/request-timeout-budget.test.js"
  "qiyue-parity:test/qiyue-parity.test.js"
  "analyze-url-parity:test/analyze-url-parity.test.js"
  "source-vars:test/source-vars.test.js"
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
  # ⭐⭐⭐ **主线程门禁**（2026-10-25 真机闪退）：非 @MainActor 的函数碰 UIKit ⇒ 后台线程调到就崩
  "mainactor-ui-guard:test/mainactor-ui-guard.test.js"
  "real-timeout-guard:test/real-timeout-guard.test.js"
  # ⭐⭐⭐⭐⭐ **Linux 编译门禁**（2026-10-25 build253 CI 失败事故）：
  #   改了 SourceService.swift 沙盒却全绿 ⇒ 因为它**根本没被编过** ⇒ 多一个 } 就把 CI 挂了
  #   ⇒ 现在用 stub 让它**真被 swiftc 编译** ⇒ 3 秒抓到 ⇒ 不用等 5 分钟 CI
  "linux-compile:test/linux-compile-gate.test.js"
  # ⭐⭐⭐ 发现页过滤 + 文件导入（2026-10-26 用户反馈三条）
  "source-import-discover:test/source-import-discover.test.js"
  # ⭐⭐⭐⭐⭐ **op 结构一致性**（2026-10-25 真机 build253 实证）：
  #   runBookInfo 返回 ["book": {...}]（嵌套）而 isTrustworthy 读顶层 ⇒ 详情页 100% 失败
  #   ⇒ 沙盒对拍**直接调引擎** ⇒ 绕过 App 侧这层 ⇒ 永远抓不到 ⭐⭐⭐
  "op-shape-consistency:test/op-shape-consistency.test.js"
  # ⭐⭐⭐ UAA 四合一（知秋）：「获取Token」链路（2026-10-27 用户报「获取 token 不了」）
  #   ⇒ 真服务器回 403「无效JWT」⇒ 根因：`source.getVariable()` 在轻阅返回的是整份变量 JSON
  #   ⇒ 轻阅版源把 token 改存「书源变量·token」项 + 没有 token 就不发 authorization 头
  "uaa-token:test/uaa-token.test.js"
  # ⭐⭐⭐ **站方变量 / 书源变量 拆两套**（Legado 语义 · 通用书源系统的地基）
  #   ⇒ 混成一套 ⇒ UAA 源 403「无效JWT」拿不到 token + NovelHub 改筛选冲掉解锁态
  "source-variable-contract:test/source-variable-contract.test.js"
  # ⭐⭐⭐⭐⭐ **站方能力面体检**（通用性的地基 · 2026-10-27）
  #   ⇒ 扫真实语料（125 源 + 聚合源）用到的站方 API 面 ⇒ 跟轻阅实现的面对账
  #   ⇒ **新出现的站方 API 必须当场定性**（实现 / 登记为例外）⇒ 不用人肉适配 ⭐
  "station-capability-audit:test/station-capability-audit.test.js"
  # ⭐⭐⭐⭐⭐ **jsLib 顶层 let/const 的全局可见性**（2026-10-27 真机「详情目录都不能用」）
  #   ⇒ 间接 eval 里 `let`/`const` 是 **eval 局部** ⇒ 规则里看不见 ⇒ URL 空
  #   ⇒ 引擎 JSC/Node 有「显式导出」⇒ **只有 App 的 WebView 后端漏了** ⇒ 沙盒绿、真机挂
  "jslib-global-export:test/jslib-global-export.test.js"
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
printf "合计通过 %d 项 / 失败 %d 个门禁\n" "$TOTAL_PASS" "$TOTAL_FAIL"


if [ ${#SKIPPED[@]} -gt 0 ]; then
  printf "⏭ 跳过的门禁（**没验到，不算通过**）：%s\n" "${SKIPPED[*]}"
fi
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
# ⚠️⚠️ **有门禁被跳过时不能叫「全绿」**（2026-10-21）：
#    跳过的门禁**根本没跑**（站方抖动 / 缺本机依赖 / 没装 swiftc），
#    说「全绿」= 假绿 ⇒ 必须把跳过数量标出来。
if [ "$TOTAL_FAIL" -eq 0 ]; then
  if [ ${#SKIPPED[@]} -gt 0 ]; then
    echo "✅ 无失败（⚠️ 但有 ${#SKIPPED[@]} 个门禁被跳过 ⇒ 那部分**没验到**）"
  else
    echo "✅ 门禁全绿"
  fi
  exit 0
else
  echo "❌ 门禁没过"
  exit 1
fi
