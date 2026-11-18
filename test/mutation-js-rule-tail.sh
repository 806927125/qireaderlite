#!/usr/bin/env bash
# ============================================================
# ⭐⭐⭐⭐⭐ **变异测试**：`@js:` 规则不许在正文里被「尾部 JS」腰斩（2026-11-18 真机真凶）
#
# 跑法：bash test/mutation-js-rule-tail.sh
#
# 为什么要有这个门禁：
#   门禁「全绿」有两种可能：① 实现对 ② **门禁没抓到东西**（平凡通过）⭐⭐⭐
#   ⇒ 所以每个断言都要问「**把实现改坏，它会不会红**」⭐
#
# ⚠️ **复原用「拷副本」**，不用 `git checkout` ⇒ 不会冲掉未提交的改动（踩过）⭐
# ⚠️ **改坏的锚点必须跟当前代码形状一致** ⇒ 代码一改锚点要跟着改 ⭐⭐⭐
# ============================================================
set -uo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
ANL="QiReaderLite/Resources/engine/rule-analyzer.js"

BAK="$TMP/backup"; mkdir -p "$BAK"
cp "$ANL" "$BAK/anl.js"
restore() { cp "$BAK/anl.js" "$ANL"; }
trap 'restore; rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { if [ "$1" = "0" ]; then pass=$((pass+1)); echo "  ✓ $2"; else fail=$((fail+1)); echo "  ✗ $2"; fi; }

run_gate() {
  # ① 真实文件（就地变异）
  node test/js-rule-tail-contract.test.js > "$TMP/gate.txt" 2>&1
  local rc=$?
  if grep -qE "ReferenceError|SyntaxError|ENOENT|Error:" "$TMP/gate.txt"; then
    echo "    (门禁崩了 ⇒ 算失败)"; tail -8 "$TMP/gate.txt"; return 2
  fi
  if ! grep -qE "通过 [0-9]+ / 失败 [0-9]+" "$TMP/gate.txt"; then
    echo "    (没有汇总行 ⇒ 可疑 ⇒ 算失败)"; tail -8 "$TMP/gate.txt"; return 2
  fi
  return $rc
}

echo "=== ⓪ 基准：不改任何东西 ⇒ 门禁必须绿 ==="
run_gate; rc=$?
[ $rc -eq 0 ] && ok 0 "基准：门禁绿 ✅" || { ok 1 "基准：门禁**不绿**（改之前就红 ⇒ 先修基准）"; tail -12 "$TMP/gate.txt"; }

echo "=== ① 基座必红：用【修复前】的引擎 ⇒ 门禁必须红 ==="
# ⭐⭐⭐ **基座不能取 HEAD**（修复提交后 HEAD 就是修好的版本了 ⇒ 基座变绿 ⇒ 门禁变成摆设）
#   ⇒ 正确取法：**引入修复的那个 commit 的父版本**（`git log -S` 找）
#   ⇒ 找不到（浅克隆 / CI）⇒ 退回「去掉保护」当基座（等价于修复前的行为）⭐⭐⭐
mkdir -p "$TMP/base-engine"
cp QiReaderLite/Resources/engine/*.js "$TMP/base-engine/" 2>/dev/null
FIX_COMMIT="$(git log -S 'isJsPrefixed' --format='%H' -- "$ANL" 2>/dev/null | tail -1)"
BASE_COMMIT=""
if [ -n "$FIX_COMMIT" ]; then
  BASE_COMMIT="$(git rev-parse "${FIX_COMMIT}^" 2>/dev/null || true)"
fi
if [ -n "$BASE_COMMIT" ]; then
  git show "${BASE_COMMIT}:$ANL" > "$TMP/base-engine/rule-analyzer.js" 2>/dev/null
  git show "${BASE_COMMIT}:QiReaderLite/Resources/engine/engine.js" > "$TMP/base-engine/engine.js" 2>/dev/null
  echo "    (基座 = 修复前的 commit ${BASE_COMMIT:0:8})"
else
  # 兜底：把「保护」去掉 = 修复前的行为
  echo "    (找不到修复前的 commit ⇒ 用「去掉保护」当基座)"
  python3 - <<'PYMUTBASE'
p = "QiReaderLite/Resources/engine/rule-analyzer.js"
s = open(p, encoding="utf-8").read()
old = "if (!isJsPrefixed) {"
new = "if (true) {"
assert old in s, "锚点没找到"
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYMUTBASE
  cp "$ANL" "$TMP/base-engine/rule-analyzer.js"
  restore
fi
if [ ! -s "$TMP/base-engine/rule-analyzer.js" ]; then
  ok 1 "取不到修复前的 rule-analyzer.js（git show 失败）"
else
  QR_ENGINE_DIR="$TMP/base-engine" node test/js-rule-tail-contract.test.js > "$TMP/base.txt" 2>&1
  rc=$?
  if [ $rc -ne 0 ]; then
    ok 0 "基座（修复前）⇒ 门禁红 ✅（证明门禁抓的是真问题）"
    grep -E "✗" "$TMP/base.txt" | head -4 | sed 's/^/      /'
  else
    ok 1 "基座（修复前）⇒ 门禁**居然绿** ⇒ 门禁是摆设 ❗"
  fi
fi

echo "=== ② 变异：把「@js: 不取尾部」的保护去掉 ⇒ 门禁必须红 ==="
python3 - <<'PYMUT'
p = "QiReaderLite/Resources/engine/rule-analyzer.js"
s = open(p, encoding="utf-8").read()
old = "if (!isJsPrefixed) {"
new = "if (true) {"
assert old in s, "锚点没找到（代码形状变了？）"
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYMUT
run_gate; rc=$?
[ $rc -ne 0 ] && { ok 0 "变异①（去掉保护）⇒ 门禁红 ✅"; grep -E "✗" "$TMP/gate.txt" | head -3 | sed 's/^/      /'; } \
             || { ok 1 "变异①（去掉保护）⇒ 门禁**绿** ⇒ 门禁没牙齿 ❗"; }
restore

echo "=== ③ 变异：保护加上长度限制（只有短规则受保护）⇒ 门禁必须红 ==="
python3 - <<'PYMUT'
p = "QiReaderLite/Resources/engine/rule-analyzer.js"
s = open(p, encoding="utf-8").read()
old = "var isJsPrefixed = /^\\s*@js:/i.test(String(rule || ''));"
new = "var isJsPrefixed = /^\\s*@js:/i.test(String(rule || '')) && String(rule || '').length < 1000;"
assert old in s, "锚点没找到（代码形状变了？）"
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYMUT
run_gate; rc=$?
[ $rc -ne 0 ] && { ok 0 "变异③（长度限制）⇒ 门禁红 ✅"; grep -E "✗" "$TMP/gate.txt" | head -3 | sed 's/^/      /'; } \
             || { ok 1 "变异③（长度限制）⇒ 门禁**绿** ⇒ 门禁没牙齿 ❗"; }
restore

echo "=== ④ 复原后再跑一次 ⇒ 必须绿（证明复原干净）==="
run_gate; rc=$?
[ $rc -eq 0 ] && ok 0 "复原后门禁绿 ✅" || { ok 1 "复原后门禁**不绿** ⇒ 复原没干净"; tail -10 "$TMP/gate.txt"; }

echo ""
echo "变异测试：通过 $pass / 失败 $fail"
[ $fail -eq 0 ] || exit 1
exit 0
