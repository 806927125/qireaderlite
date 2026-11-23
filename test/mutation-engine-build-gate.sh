#!/usr/bin/env bash
# ============================================================
# ⭐⭐⭐⭐⭐ **变异测试**：Linux 编译门禁**必须**抓得住「引擎包编译失败」（2026-11-24 build318 实证）
#
# 跑法：bash test/mutation-engine-build-gate.sh
#
# ⚠️⚠️⚠️ **为什么要有这个门禁**（2026-11-24 真机事故）⭐⭐⭐：
#   我改了引擎里的 `AnalyzeUrl.swift`（写了 `request.url.absoluteString`，
#   而 `HTTPRequest.url` 是 **String** ⇒ macOS 编译失败）⭐⭐⭐
#   ⇒ **Linux 沙盒门禁全绿** ⇒ ⇒ 推到 CI ⇒ **BUILD FAILED**（白等一轮 CI）⭐⭐⭐
#
#   ⇒ **真因不是「我改错了」，是「门禁根本没编那个文件」** ⭐⭐⭐
#   ⇒ 而 `linux-compile-gate.sh` 里那层 `swift build … | tail -3`
#     **把编译失败吞掉了**（管道的退出码 = `tail` 的）⇒ ⇒ **引擎编不过也不报红** ⭐⭐⭐
#   ⇒ ⇒ 门禁拿**旧 .swiftmodule** 继续编 App ⇒ ⇒ **假绿** ⭐⭐⭐⭐⭐
#
# ⭐⭐⭐ **本门禁证明那条修复真的有效**：把引擎改坏 ⇒ 门禁**必须红** ⇒ 复原 ⇒ 必须绿 ⭐⭐⭐
#   （否则「修好了」只是我以为修好了 ⇒ 同样的事还会再犯）⭐⭐⭐
# ============================================================
set -uo pipefail
cd "$(dirname "$0")/.."

ENGINE_FILE="LegadoEngine/Sources/ChaiyueEngine/Network/AnalyzeUrl.swift"
GATE="test/linux-compile-gate.sh"

if [ ! -f "$ENGINE_FILE" ]; then
  echo "⚠️ 跳过：找不到 $ENGINE_FILE"
  exit 0
fi

TMP="$(mktemp -d)"
BAK="$TMP/AnalyzeUrl.swift.bak"
cp "$ENGINE_FILE" "$BAK"
restore() { cp "$BAK" "$ENGINE_FILE"; }
trap 'restore; rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { if [ "$1" = "0" ]; then pass=$((pass+1)); echo "  ✓ $2"; else fail=$((fail+1)); echo "  ✗ $2"; fi; }

echo "=== 变异测试：引擎包编译失败 ⇒ Linux 编译门禁必须红 ==="

# ── ① 基线：门禁本身是绿的 ─────────────────────────────────────
echo "▶ [①] 基线（未变异）"
if bash "$GATE" > "$TMP/base.txt" 2>&1; then
  ok 0 "基线：门禁通过"
else
  ok 1 "基线：门禁本来就不绿（先修好再来做变异）"
  tail -20 "$TMP/base.txt" | sed 's/^/     /'
  echo "通过 $pass / 失败 $fail"
  exit 1
fi

# ── ② 变异：给引擎文件塞一个**编译错误** ───────────────────────
echo "▶ [②] 变异：往引擎文件里塞一个编译错误"
printf '\n// ==== 变异：故意写错（验证门禁有牙齿）====\nlet __mutationBroken: Int = "这不是数字"\n' >> "$ENGINE_FILE"
# ⚠️ 变异代码**不写在同一行的注释后面** ⇒ 否则注释会把右括号吃掉 ⇒ 编译失败原因会变得莫名其妙 ⭐⭐⭐

if bash "$GATE" > "$TMP/mut.txt" 2>&1; then
  ok 1 "⭐⭐⭐ **变异后门禁居然还是绿的 ⇒ 门禁没有牙齿（假绿）**"
  echo "     ⇒ 这正是 build318 CI 挂掉的那类漏检"
  tail -15 "$TMP/mut.txt" | sed 's/^/     /'
else
  ok 0 "⭐ 变异后门禁**红了** ⇒ 引擎编译失败能被抓住"
  grep -E "❌|error:" "$TMP/mut.txt" | head -6 | sed 's/^/     /'
fi

# ── ③ 复原后必须恢复绿 ───────────────────────────────────────
echo "▶ [③] 复原后必须恢复绿"
restore
if bash "$GATE" > "$TMP/after.txt" 2>&1; then
  ok 0 "复原后门禁恢复绿"
else
  ok 1 "复原后门禁仍红 ⇒ 变异没复原干净"
  tail -15 "$TMP/after.txt" | sed 's/^/     /'
fi

echo
echo "通过 $pass / 失败 $fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
