#!/usr/bin/env bash
# ============================================================
# ⭐⭐⭐⭐⭐ **变异测试**：把实现改坏 ⇒ 门禁必须红
#
# 跑法：bash test/mutation-station-var.sh
#
# 为什么要有这个门禁：
#   门禁「全绿」有两种可能：① 实现对 ② **门禁没抓到东西**（平凡通过）⭐⭐⭐
#   ⇒ 所以每个断言都要问「**把实现改坏，它会不会红**」⭐
#   ⇒ 这个脚本就是把实现改坏 7 次，看门禁是不是每次都红 ⭐⭐⭐
# ============================================================
set -uo pipefail
cd "$(dirname "$0")/.."

SWIFTC=""
for c in /tmp/swift/usr/bin/swiftc \
         "$(dirname "$(dirname "$0")")/../.toolchain/swift/usr/bin/swiftc" \
         "$(command -v swiftc || true)"; do
  [ -x "$c" ] && { SWIFTC="$c"; break; }
done
if [ -n "$SWIFTC" ] && [ ! -x /tmp/swift/usr/bin/swiftc ]; then
  WLIB="$(cd "$(dirname "$(dirname "$SWIFTC")")" && pwd)"
  [ -d "$WLIB" ] && { mkdir -p /tmp 2>/dev/null; ln -sfn "$WLIB" /tmp/swift 2>/dev/null || true; }
fi
[ -d /tmp/swift/usr/lib/swift/linux ] && export LD_LIBRARY_PATH="/tmp/swift/usr/lib/swift/linux:${LD_LIBRARY_PATH:-}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

VARS="QiReaderLite/Core/SourceVariables.swift"
SVC="QiReaderLite/Core/SourceService.swift"
BACK="QiReaderLite/Core/LegadoEngineBackend.swift"

pass=0; fail=0
ok() { if [ "$1" = "0" ]; then pass=$((pass+1)); echo "  ✓ $2"; else fail=$((fail+1)); echo "  ✗ $2"; fi; }

restore() { git checkout -- "$VARS" "$SVC" "$BACK" 2>/dev/null || true; }
trap 'restore; rm -rf "$TMP"' EXIT

# 跑 Swift 门禁（真编真跑）⇒ 退出码非 0 = 红
run_swift_gate() {
  mkdir -p "$TMP/m"
  cp test/station-var-form-test.swift "$TMP/m/main.swift"
  if ! "$SWIFTC" -O "$TMP/m/main.swift" "$VARS" -o "$TMP/m/t" 2>"$TMP/m/err.txt"; then
    echo "COMPILE_ERROR"; return 2
  fi
  "$TMP/m/t" > "$TMP/m/out.txt" 2>&1
  return $?
}

echo "=== ① 证据自证：回传时值没变也当成「站方写的」 ==="
python3 - <<'PY'
import re
p = "QiReaderLite/Core/SourceService.swift"
s = open(p, encoding="utf-8").read()
s2 = s.replace("stationWroteIt(obj) ? .station : .app", ".station")
assert s != s2, "变异没生效"
open(p, "w", encoding="utf-8").write(s2)
PY
node test/source-variable-shape.test.js > "$TMP/js1.txt" 2>&1
[ $? -ne 0 ] && ok 0 "回传恒当证据 ⇒ source-variable-shape 变红 ✅" || { ok 1 "回传恒当证据 ⇒ 门禁**没红**（这条门禁没牙齿！）"; tail -5 "$TMP/js1.txt"; }
restore

echo "=== ② 证据的键不带版本（旧的污染证据继续生效） ==="
python3 - <<'PY'
p = "QiReaderLite/Core/SourceVariables.swift"
s = open(p, encoding="utf-8").read()
s2 = s.replace("sourcevariable.stationform.v2.", "sourcevariable.stationform.")
assert s != s2, "变异没生效"
open(p, "w", encoding="utf-8").write(s2)
PY
node test/source-variable-shape.test.js > "$TMP/js2.txt" 2>&1
[ $? -ne 0 ] && ok 0 "证据键去掉版本 ⇒ 变红 ✅" || { ok 1 "证据键去掉版本 ⇒ 门禁**没红**"; tail -5 "$TMP/js2.txt"; }
node test/uaa-original-station-var.test.js > "$TMP/js2b.txt" 2>&1
[ $? -ne 0 ] && ok 0 "（真源门禁也跟着红）✅" || ok 1 "真源门禁没红"
restore

echo "=== ③ 污染迁移挂在走不到的链上（灌站方变量时不迁移） ==="
python3 - <<'PY'
p = "QiReaderLite/Core/SourceService.swift"
s = open(p, encoding="utf-8").read()
s2 = s.replace("stationVariableToSeed(for:", "variable(for:")
assert s != s2, "变异没生效"
open(p, "w", encoding="utf-8").write(s2)
PY
node test/source-variable-shape.test.js > "$TMP/js3.txt" 2>&1
[ $? -ne 0 ] && ok 0 "迁移被绕开 ⇒ 变红 ✅" || { ok 1 "迁移被绕开 ⇒ 门禁**没红**"; tail -5 "$TMP/js3.txt"; }
node test/uaa-original-station-var.test.js > "$TMP/js3b.txt" 2>&1
[ $? -ne 0 ] && ok 0 "（真源门禁也跟着红）✅" || ok 1 "真源门禁没红"
restore

echo "=== ④ 引擎不报「站方改没改」 ==="
python3 - <<'PY'
p = "QiReaderLite/Core/LegadoEngineBackend.swift"
s = open(p, encoding="utf-8").read()
s2 = s.replace('dict["__sourceVariableChanged"] = (sv.text != (seededStationVariable ?? ""))',
               'dict["__sourceVariableChanged"] = true')
assert s != s2, "变异没生效"
open(p, "w", encoding="utf-8").write(s2)
PY
node test/source-variable-shape.test.js > "$TMP/js4.txt" 2>&1
[ $? -ne 0 ] && ok 0 "引擎恒报「改过」⇒ 变红 ✅" || { ok 1 "引擎恒报「改过」⇒ 门禁**没红**"; tail -5 "$TMP/js4.txt"; }
restore

echo "=== ⑤ 宿主写的值也当证据（自证回来了） ==="
python3 - <<'PY'
p = "QiReaderLite/Core/SourceVariables.swift"
s = open(p, encoding="utf-8").read()
old = """        case .app:
            // 宿主自己合成的（线路表）⇒ **不算证据**（它正是污染的来源）⭐
            break"""
new = """        case .app:
            UserDefaults.standard.set(isMapStyleVariable(value) ? StationVarForm.map.rawValue
                                                                : StationVarForm.credential.rawValue,
                                      forKey: stationFormPrefix + sourceUrl)"""
assert old in s, "变异锚点没找到"
open(p, "w", encoding="utf-8").write(s.replace(old, new))
PY
run_swift_gate; rc=$?
[ $rc -ne 0 ] && ok 0 "宿主写的也算证据 ⇒ Swift 门禁变红 ✅" || { ok 1 "宿主写的也算证据 ⇒ 门禁**没红**"; tail -20 "$TMP/m/out.txt"; }
restore

echo "=== ⑥ 凭据形态也当 map 形态（污染不清） ==="
python3 - <<'PY'
p = "QiReaderLite/Core/SourceVariables.swift"
s = open(p, encoding="utf-8").read()
s2 = s.replace("if defaultTableFetched(sourceUrl) { return .credential }",
               "if defaultTableFetched(sourceUrl) { return .map }")
assert s != s2, "变异没生效"
open(p, "w", encoding="utf-8").write(s2)
PY
run_swift_gate; rc=$?
[ $rc -ne 0 ] && ok 0 "凭据形态当 map ⇒ Swift 门禁变红 ✅" || { ok 1 "凭据形态当 map ⇒ 门禁**没红**"; tail -20 "$TMP/m/out.txt"; }
restore

echo "=== ⑦ 迁移里的清污染逻辑删掉 ==="
python3 - <<'PY'
p = "QiReaderLite/Core/SourceVariables.swift"
s = open(p, encoding="utf-8").read()
old = 'guard form(for: sourceUrl) == .credential, isMapStyleVariable(current) else { return current }'
new = 'guard false else { return current }'
assert old in s, "变异锚点没找到"
open(p, "w", encoding="utf-8").write(s.replace(old, new))
PY
run_swift_gate; rc=$?
[ $rc -ne 0 ] && ok 0 "清污染逻辑删掉 ⇒ Swift 门禁变红 ✅" || { ok 1 "清污染逻辑删掉 ⇒ 门禁**没红**"; tail -20 "$TMP/m/out.txt"; }
restore

echo "=== ⑧ 宿主写 map 的凭据拦截删掉 ==="
python3 - <<'PY'
p = "QiReaderLite/Core/SourceVariables.swift"
s = open(p, encoding="utf-8").read()
old = "guard form(for: sourceUrl) != .credential else { return }"
new = "guard true else { return }"
assert old in s, "变异锚点没找到"
open(p, "w", encoding="utf-8").write(s.replace(old, new))
PY
run_swift_gate; rc=$?
[ $rc -ne 0 ] && ok 0 "凭据拦截删掉 ⇒ Swift 门禁变红 ✅" || { ok 1 "凭据拦截删掉 ⇒ 门禁**没红**"; tail -20 "$TMP/m/out.txt"; }
restore

echo "=== ⑨ 复原后门禁必须恢复绿（证明脚本没把文件改坏） ==="
run_swift_gate; rc=$?
[ $rc -eq 0 ] && ok 0 "Swift 门禁恢复绿 ✅" || { ok 1 "复原后还是红 ⇒ 脚本把文件改坏了！"; tail -20 "$TMP/m/out.txt"; }
node test/source-variable-shape.test.js > "$TMP/js9.txt" 2>&1
[ $? -eq 0 ] && ok 0 "source-variable-shape 恢复绿 ✅" || { ok 1 "source-variable-shape 复原后还是红"; tail -5 "$TMP/js9.txt"; }
node test/uaa-original-station-var.test.js > "$TMP/js9b.txt" 2>&1
[ $? -eq 0 ] && ok 0 "uaa-original-station-var 恢复绿 ✅" || ok 1 "uaa-original-station-var 复原后还是红"

echo ""
echo "$( [ $fail -eq 0 ] && echo "✅" || echo "❌" ) 变异测试：通过 $pass / 失败 $fail"
exit $fail
