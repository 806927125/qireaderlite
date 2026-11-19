#!/usr/bin/env bash
# ============================================================
# ⭐⭐⭐⭐⭐ **变异测试**：引擎替换契约（2026-11-19）
#
# 跑法：bash test/mutation-engine-replacement.sh
#
# 为什么要有这个门禁：
#   门禁「全绿」有两种可能：① 实现真的对 ② **门禁没抓到东西**（平凡通过）⭐⭐⭐
#   ⇒ 所以每个断言都要问「**把实现改坏，它会不会红**」⭐
#
# ⚠️ **复原用「拷副本」**，不用 `git checkout` ⇒ 不会冲掉未提交的改动 ⭐⭐⭐
# ⚠️ **改坏的锚点必须跟当前代码形状一致** ⇒ 代码一改锚点要跟着改 ⭐⭐⭐
set -uo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
BE="QiReaderLite/Core/LegadoEngineBackend.swift"

BAK="$TMP/backup"; mkdir -p "$BAK"
PBX="QiReaderLite.xcodeproj/project.pbxproj"
cp "$BE" "$BAK/be.swift"
cp "$PBX" "$BAK/pbxproj"
# ⚠️⚠️ **复原只用拷副本** ⇒ 绝不用 `git checkout`（会冲掉未提交改动 ⭐⭐⭐）
restore() { cp "$BAK/be.swift" "$BE"; cp "$BAK/pbxproj" "$PBX"; }
trap 'restore; rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { if [ "$1" = "0" ]; then pass=$((pass+1)); echo "  ✓ $2"; else fail=$((fail+1)); echo "  ✗ $2"; fi; }

run_gate() {
  node test/engine-replacement-contract.test.js > "$TMP/gate.txt" 2>&1
  return $?
}

echo "=== ⓪ 基准：不改任何东西 ⇒ 门禁必须绿 ==="
run_gate; rc=$?
[ $rc -eq 0 ] && ok 0 "基准：门禁绿 ✅" || { ok 1 "基准：门禁**不绿**"; tail -12 "$TMP/gate.txt"; }

echo "=== ① 变异：把「__sourceVariableChanged」回传删掉 ⇒ 门禁必须红 ==="
python3 - <<'PYMUT'
p = "QiReaderLite/Core/LegadoEngineBackend.swift"
s = open(p, encoding="utf-8").read()
# ⚠️⚠️ **锚点必须【跟着实现走】**（2026-11-19 实证）：
#   站方变量改成【两格合并】后，回传的形态变成 `stationVar != session.stationSeeded`
#   ⇒ 旧锚点找不到 ⇒ **变异无效 ⇒ 门禁没牙齿**（差点被放过）⭐⭐⭐
#   ⇒ 而且要**删掉全部两处**（`String.replace` 不带 g 只换第一处！）⭐⭐⭐
old = 'out["__sourceVariableChanged"] = (stationVar != session.stationSeeded)'
assert old in s, "锚点没找到（代码形状变了？）"
s = s.replace(old, '// 变异：删掉「站方到底改没改」的回传')
open(p, "w", encoding="utf-8").write(s)
PYMUT
run_gate; rc=$?
[ $rc -ne 0 ] && { ok 0 "变异①（删掉 __sourceVariableChanged）⇒ 门禁红 ✅"; grep -E "✗" "$TMP/gate.txt" | head -3 | sed 's/^/      /'; } \
             || { ok 1 "变异①⇒ 门禁**绿** ⇒ 门禁没牙齿 ❗"; }
restore

echo "=== ② 变异：把「login」op 的接线删掉 ⇒ 门禁必须红 ==="
python3 - <<'PYMUT'
p = "QiReaderLite/Core/LegadoEngineBackend.swift"
s = open(p, encoding="utf-8").read()
old = 'if op == "login" || op == "loginProbe" {'
assert old in s, "锚点没找到（代码形状变了？）"
open(p, "w", encoding="utf-8").write(s.replace(old, 'if false {', 1))
PYMUT
run_gate; rc=$?
[ $rc -ne 0 ] && { ok 0 "变异②（删掉 login 接线）⇒ 门禁红 ✅"; grep -E "✗" "$TMP/gate.txt" | head -3 | sed 's/^/      /'; } \
             || { ok 1 "变异②⇒ 门禁**绿** ⇒ 门禁没牙齿 ❗"; }
restore

echo "=== ③ 变异：把老引擎的 SPM 依赖加回来 ⇒ 门禁必须红 ==="
python3 - <<'PYMUT'
p = "QiReaderLite.xcodeproj/project.pbxproj"
s = open(p, encoding="utf-8").read()
old = 'relativePath = LegadoEngine;'
assert old in s, "锚点没找到（代码形状变了？）"
open(p, "w", encoding="utf-8").write(s.replace(old, 'repositoryURL = "https://github.com/806927125/legado-engine.git";\n\t\t\trequirement = { kind = branch; branch = "feat/sextant-jsonpath"; };', 1))
PYMUT
run_gate; rc=$?
[ $rc -ne 0 ] && { ok 0 "变异③（把老引擎依赖加回来）⇒ 门禁红 ✅"; grep -E "✗" "$TMP/gate.txt" | head -3 | sed 's/^/      /'; } \
             || { ok 1 "变异③⇒ 门禁**绿** ⇒ 门禁没牙齿 ❗"; }
restore

echo "=== ④ 复原后再跑一次 ⇒ 必须绿（证明复原干净）==="
run_gate; rc=$?
[ $rc -eq 0 ] && ok 0 "复原后门禁绿 ✅" || { ok 1 "复原后门禁**不绿** ⇒ 复原没干净"; tail -10 "$TMP/gate.txt"; }

echo ""
echo "变异测试：通过 $pass / 失败 $fail"
[ $fail -eq 0 ] || exit 1
exit 0
