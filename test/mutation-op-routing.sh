#!/usr/bin/env bash
# ============================================================
# ⭐⭐⭐⭐⭐ **变异测试**：op 分流契约（2026-10-29 真机回归）
#
# 跑法：bash test/mutation-op-routing.sh
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
SVC="QiReaderLite/Core/SourceService.swift"

BAK="$TMP/backup"; mkdir -p "$BAK"
cp "$SVC" "$BAK/svc.swift"
restore() { cp "$BAK/svc.swift" "$SVC"; }
trap 'restore; rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { if [ "$1" = "0" ]; then pass=$((pass+1)); echo "  ✓ $2"; else fail=$((fail+1)); echo "  ✗ $2"; fi; }

run_gate() {
  node test/op-routing-contract.test.js > "$TMP/gate.txt" 2>&1
  return $?
}

echo "=== ⓪ 基准：不改任何东西 ⇒ 门禁必须绿 ==="
run_gate; rc=$?
[ $rc -eq 0 ] && ok 0 "基准：门禁绿 ✅" || { ok 1 "基准：门禁**不绿**（改之前就红 ⇒ 先修基准）"; tail -12 "$TMP/gate.txt"; }

echo "=== ① 把「login」切回新引擎（⇒ 站方 setVariable 失效 ⇒ 发现页空 + 500）==="
python3 - <<'PYMUT'
p = "QiReaderLite/Core/SourceService.swift"
s = open(p, encoding="utf-8").read()
old = 'let raw = try await RuleSandbox.shared.invoke("login", p, source: source)'
new = 'let raw = try await Self.invokeEngine("login", p, source: source)'
assert old in s, "锚点没找到（代码形状变了？）"
open(p, "w", encoding="utf-8").write(s.replace(old, new))
PYMUT
run_gate; rc=$?
[ $rc -ne 0 ] && ok 0 "login 切新引擎 ⇒ 门禁变红 ✅" || { ok 1 "login 切新引擎 ⇒ 门禁**没红**（门禁没牙齿！）"; tail -12 "$TMP/gate.txt"; }
restore

echo "=== ② 把「filterAction」切回新引擎（⇒ 站方 put('order') 失效 ⇒ 500）==="
python3 - <<'PYMUT'
p = "QiReaderLite/Core/SourceService.swift"
s = open(p, encoding="utf-8").read()
old = 'let raw = try await RuleSandbox.shared.invoke("filterAction", p, source: source)'
new = 'let raw = try await Self.invokeEngine("filterAction", p, source: source)'
assert old in s, "锚点没找到（代码形状变了？）"
open(p, "w", encoding="utf-8").write(s.replace(old, new))
PYMUT
run_gate; rc=$?
[ $rc -ne 0 ] && ok 0 "filterAction 切新引擎 ⇒ 门禁变红 ✅" || { ok 1 "filterAction 切新引擎 ⇒ 门禁**没红**（门禁没牙齿！）"; tail -12 "$TMP/gate.txt"; }
restore

echo "=== ③ 把「sourceVars」退回老引擎（⇒ 只读的 op 不该回老引擎）==="
python3 - <<'PYMUT'
p = "QiReaderLite/Core/SourceService.swift"
s = open(p, encoding="utf-8").read()
old = 'guard let raw = try? await Self.invokeEngine("sourceVars", ["source": srcDict], source: source),'
new = 'guard let raw = try? await RuleSandbox.shared.invoke("sourceVars", ["source": srcDict], source: source),'
assert old in s, "锚点没找到（代码形状变了？）"
open(p, "w", encoding="utf-8").write(s.replace(old, new))
PYMUT
run_gate; rc=$?
[ $rc -ne 0 ] && ok 0 "sourceVars 退回老引擎 ⇒ 门禁变红 ✅" || { ok 1 "sourceVars 退回老引擎 ⇒ 门禁**没红**（门禁没牙齿！）"; tail -12 "$TMP/gate.txt"; }
restore

echo "=== ④ 复原后门禁必须恢复绿 ==="
run_gate; rc=$?
[ $rc -eq 0 ] && ok 0 "复原后门禁恢复绿 ✅" || { ok 1 "复原后门禁还是红 ⇒ 脚本把文件改坏了！"; tail -12 "$TMP/gate.txt"; }

echo ""
echo "$( [ $fail -eq 0 ] && echo "✅" || echo "❌" ) 变异测试：通过 $pass / 失败 $fail"
exit $fail
