#!/usr/bin/env bash
# ============================================================
# ⭐⭐⭐⭐⭐ **变异测试**：登录写变量的行为门禁（2026-10-29 真机回归）
#
# 跑法：bash test/mutation-login-writes-vars.sh
#
# 为什么要有这个门禁：
#   门禁「全绿」有两种可能：① 实现对 ② **门禁没抓到东西**（平凡通过）⭐⭐⭐
#   ⇒ 所以每个断言都要问「**把实现改坏，它会不会红**」⭐
#
# ⚠️ **复原用「拷副本」**，不用 `git checkout` ⇒ 不会冲掉未提交的改动（踩过）⭐
# ============================================================
set -uo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
API="QiReaderLite/Resources/engine/source-api.js"

BAK="$TMP/backup"; mkdir -p "$BAK"
cp "$API" "$BAK/api.js"
restore() { cp "$BAK/api.js" "$API"; }
trap 'restore; rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { if [ "$1" = "0" ]; then pass=$((pass+1)); echo "  ✓ $2"; else fail=$((fail+1)); echo "  ✗ $2"; fi; }

run_gate() {
  node test/login-writes-vars.test.js > "$TMP/gate.txt" 2>&1
  return $?
}

echo "=== ⓪ 基准：不改任何东西 ⇒ 门禁必须绿 ==="
run_gate; rc=$?
[ $rc -eq 0 ] && ok 0 "基准：门禁绿 ✅" || { ok 1 "基准：门禁**不绿**"; tail -12 "$TMP/gate.txt"; }

echo "=== ① source.put 不再标 dirty（⇒ 回传丢了 ⇒ aid 写不进去 ⇒ explore 500 ⇒ 发现页空）==="
python3 - <<'PYMUT'
p = "QiReaderLite/Resources/engine/source-api.js"
s = open(p, encoding="utf-8").read()
old = "      QR.__qrDirtyVars = vars;"
i = s.find("wrapped.put = function")
j = s.find(old, i)
assert i >= 0 and j > 0 and j - i < 800, "put 里的锚点没找到（代码形状变了？）"
s = s[:j] + "      // （变异：不标 dirty）" + s[j+len(old):]
open(p, "w", encoding="utf-8").write(s)
PYMUT
run_gate; rc=$?
[ $rc -ne 0 ] && ok 0 "put 不标 dirty ⇒ 门禁变红 ✅" || { ok 1 "put 不标 dirty ⇒ 门禁**没红**（门禁没牙齿！）"; tail -12 "$TMP/gate.txt"; }
restore

echo "=== ② source.setVariable 不再标 dirty（⇒ 站方变量（token）丢）==="
python3 - <<'PYMUT'
p = "QiReaderLite/Resources/engine/source-api.js"
s = open(p, encoding="utf-8").read()
old = "QR.__qrDirtyVariable = variable;"
i = s.find("wrapped.setVariable = function")
j = s.find(old, i)
assert i >= 0 and j > 0 and j - i < 1200, "setVariable 里的锚点没找到（代码形状变了？）"
s = s[:j] + "// （变异：不标 dirty）" + s[j+len(old):]
open(p, "w", encoding="utf-8").write(s)
PYMUT
run_gate; rc=$?
[ $rc -ne 0 ] && ok 0 "setVariable 不标 dirty ⇒ 门禁变红 ✅" || { ok 1 "setVariable 不标 dirty ⇒ 门禁**没红**（门禁没牙齿！）"; tail -12 "$TMP/gate.txt"; }
restore

echo "=== ③ 复原后门禁必须恢复绿 ==="
run_gate; rc=$?
[ $rc -eq 0 ] && ok 0 "复原后门禁恢复绿 ✅" || { ok 1 "复原后门禁还是红 ⇒ 脚本把文件改坏了！"; tail -12 "$TMP/gate.txt"; }

echo ""
echo "$( [ $fail -eq 0 ] && echo "✅" || echo "❌" ) 变异测试：通过 $pass / 失败 $fail"
exit $fail
