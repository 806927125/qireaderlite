#!/usr/bin/env bash
# ============================================================
# ⭐⭐⭐⭐⭐ **变异测试**：柴阅移植契约（2026-11-21）
#
# 跑法：bash test/mutation-engine-replacement.sh
#
# 为什么要有这个门禁：
#   门禁「全绿」有两种可能：① 实现真的对 ② **门禁没抓到东西**（平凡通过）⭐⭐⭐
#   ⇒ 所以每个断言都要问「**把实现改坏，它会不会红**」⭐
#
# ⚠️⚠️ **复原用「拷副本」**，不用 `git checkout` ⇒ 不会冲掉未提交的改动 ⭐⭐⭐
# ⚠️⚠️ **改坏的锚点必须跟当前代码形状一致** ⇒ 代码一改锚点要跟着改 ⭐⭐⭐
#   （记忆里的老坑：锚点找不到 ⇒ 变异无效 ⇒ 门禁没牙齿 ⇒ 差点被放过）⭐⭐⭐
set -uo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
BE="QiReaderLite/Core/LegadoEngineBackend.swift"
RT="QiReaderLite/Core/ChaiyueRuntime.swift"
MP="LegadoEngine/Sources/ChaiyueEngine/Compat/ChaiyueStoreMapping.swift"

BAK="$TMP/backup"; mkdir -p "$BAK"
cp "$BE" "$BAK/be.swift"
cp "$RT" "$BAK/rt.swift"
cp "$MP" "$BAK/mp.swift"
# ⚠️⚠️ **复原只用拷副本** ⇒ 绝不用 `git checkout`（会冲掉未提交改动 ⭐⭐⭐）
restore() { cp "$BAK/be.swift" "$BE"; cp "$BAK/rt.swift" "$RT"; cp "$BAK/mp.swift" "$MP"; }
trap 'restore; rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { if [ "$1" = "0" ]; then pass=$((pass+1)); echo "  ✓ $2"; else fail=$((fail+1)); echo "  ✗ $2"; fi; }

run_gate() {
  node test/chaiyue-port-contract.test.js > "$TMP/gate.txt" 2>&1
  return $?
}

echo "=== ⓪ 基准：不改任何东西 ⇒ 门禁必须绿 ==="
run_gate; rc=$?
[ $rc -eq 0 ] && ok 0 "基准：门禁绿 ✅" || { ok 1 "基准：门禁**不绿**"; tail -12 "$TMP/gate.txt"; }

echo "=== ① 变异：宿主不用柴阅的 WebBook（改回自建 bridge）⇒ 门禁必须红 ==="
python3 - <<'PYMUT'
p = "QiReaderLite/Core/LegadoEngineBackend.swift"
s = open(p, encoding="utf-8").read()
old = 'let web = LegadoEngineHost.WebBook(source: parsed, environment: env)'
assert old in s, "锚点没找到（代码形状变了？）"
s = s.replace(old, 'let web = LegacyBridge(source: parsed, environment: env)')
open(p, "w", encoding="utf-8").write(s)
PYMUT
run_gate; rc=$?
[ $rc -ne 0 ] && { ok 0 "变异①（不用 WebBook）⇒ 门禁红 ✅"; grep -E "✗" "$TMP/gate.txt" | head -3 | sed 's/^/      /'; } \
             || { ok 1 "变异①⇒ 门禁**绿** ⇒ 门禁没牙齿 ❗"; }
restore

echo "=== ② 变异：exploreKinds 不走柴阅（改回静态解析）⇒ 门禁必须红 ==="
python3 - <<'PYMUT'
p = "QiReaderLite/Core/LegadoEngineBackend.swift"
s = open(p, encoding="utf-8").read()
old = 'let kinds = try await web.exploreKinds()'
assert old in s, "锚点没找到（代码形状变了？）"
s = s.replace(old, 'let kinds: [LegadoEngineHost.Kind] = []')
open(p, "w", encoding="utf-8").write(s)
PYMUT
run_gate; rc=$?
[ $rc -ne 0 ] && { ok 0 "变异②（exploreKinds 不走柴阅）⇒ 门禁红 ✅"; grep -E "✗" "$TMP/gate.txt" | head -3 | sed 's/^/      /'; } \
             || { ok 1 "变异②⇒ 门禁**绿** ⇒ 门禁没牙齿 ❗"; }
restore

echo "=== ③ 变异：宿主又开始回传站方变量（build302 的老坑回归）⇒ 门禁必须红 ==="
python3 - <<'PYMUT'
p = "QiReaderLite/Core/LegadoEngineBackend.swift"
s = open(p, encoding="utf-8").read()
old = 'return ["books": items, "total": books.count, "nextUrl": ""]'
assert old in s, "锚点没找到（代码形状变了？）"
s = s.replace(old, 'out["__sourceVars"] = "{}"\n            return ["books": items, "total": books.count, "nextUrl": ""]')
open(p, "w", encoding="utf-8").write(s)
PYMUT
run_gate; rc=$?
[ $rc -ne 0 ] && { ok 0 "变异③（又开始回传变量）⇒ 门禁红 ✅"; grep -E "✗" "$TMP/gate.txt" | head -3 | sed 's/^/      /'; } \
             || { ok 1 "变异③⇒ 门禁**绿** ⇒ 门禁没牙齿 ❗"; }
restore

echo "=== ④ 变异：书源变量写回时整份覆盖（丢掉其它项）⇒ 门禁必须红 ==="
python3 - <<'PYMUT'
p = "QiReaderLite/Core/ChaiyueRuntime.swift"
s = open(p, encoding="utf-8").read()
old = 'SourceVariables.setSourceVarItem(name, value ?? "", for: sourceKey)'
assert old in s, "锚点没找到（代码形状变了？）"
s = s.replace(old, 'SourceVariables.setVars("{}", for: sourceKey)')
open(p, "w", encoding="utf-8").write(s)
PYMUT
run_gate; rc=$?
[ $rc -ne 0 ] && { ok 0 "变异④（书源变量整份覆盖）⇒ 门禁红 ✅"; grep -E "✗" "$TMP/gate.txt" | head -3 | sed 's/^/      /'; } \
             || { ok 1 "变异④⇒ 门禁**绿** ⇒ 门禁没牙齿 ❗"; }
restore

echo "=== ⑤ 变异：站方变量与书源变量混成一格（build302 的老 bug）⇒ 门禁必须红 ==="
python3 - <<'PYMUT'
p = "LegadoEngine/Sources/ChaiyueEngine/Compat/ChaiyueStoreMapping.swift"
s = open(p, encoding="utf-8").read()
old = 'if name.hasPrefix(stationVariablePrefix) {'
assert old in s, "锚点没找到（代码形状变了？）"
s = s.replace(old, 'if name.hasPrefix(stationVariablePrefix) || name.hasPrefix(sourceVarPrefix) {')
open(p, "w", encoding="utf-8").write(s)
PYMUT
run_gate; rc=$?
[ $rc -ne 0 ] && { ok 0 "变异⑤（两格混成一格）⇒ 门禁红 ✅"; grep -E "✗" "$TMP/gate.txt" | head -3 | sed 's/^/      /'; } \
             || { ok 1 "变异⑤⇒ 门禁**绿** ⇒ 门禁没牙齿 ❗"; }
restore

echo "=== ⑥ 复原后再跑一次 ⇒ 必须绿（证明复原干净）==="
run_gate; rc=$?
[ $rc -eq 0 ] && ok 0 "复原后门禁绿 ✅" || { ok 1 "复原后门禁**不绿** ⇒ 复原没干净"; tail -10 "$TMP/gate.txt"; }

echo ""
echo "变异测试：通过 $pass / 失败 $fail"
[ $fail -eq 0 ] || exit 1
exit 0
