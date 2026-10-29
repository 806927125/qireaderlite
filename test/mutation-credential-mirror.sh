#!/usr/bin/env bash
# ============================================================
# ⭐⭐⭐⭐⭐ **变异测试**：凭据双写（2026-10-29 真机 401 根因）
#
# 跑法：bash test/mutation-credential-mirror.sh
#
# 为什么要有这个门禁：
#   门禁「全绿」有两种可能：① 实现对 ② **门禁没抓到东西**（平凡通过）⭐⭐⭐
#   ⇒ 所以每个断言都要问「**把实现改坏，它会不会红**」⭐
#
# ⚠️ **复原用「拷副本」**，不用 `git checkout` ⇒ 不会冲掉未提交的改动（踩过）⭐
# ⚠️ **改坏的锚点必须跟当前代码形状一致** ⇒ 代码一改锚点要跟着改
#    （否则「变异没生效」⇒ 门禁当然不红 ⇒ **看起来像门禁没牙齿，其实是变异没打中**）⭐⭐⭐
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
VARS="QiReaderLite/Core/SourceVariables.swift"
FORM="QiReaderLite/Core/StationVarForm.swift"

BAK="$TMP/backup"; mkdir -p "$BAK"
cp "$VARS" "$BAK/vars.swift"
restore() { cp "$BAK/vars.swift" "$VARS"; }
trap 'restore; rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { if [ "$1" = "0" ]; then pass=$((pass+1)); echo "  ✓ $2"; else fail=$((fail+1)); echo "  ✗ $2"; fi; }

# 跑 Swift 行为门禁（真编真跑）⇒ 退出码非 0 = 红
run_swift_gate() {
  local dir="$TMP/m$$"
  mkdir -p "$dir"
  cp test/station-var-form-test.swift "$dir/main.swift"
  if ! "$SWIFTC" -O "$dir/main.swift" "$VARS" "$FORM" QiReaderLite/Core/EngineLog.swift -o "$dir/t" 2>"$dir/err.txt"; then
    echo "COMPILE_ERROR"; cat "$dir/err.txt" | head -6; return 2
  fi
  "$dir/t" > "$dir/out.txt" 2>&1
  return $?
}

echo "=== ⓪ 基准：不改任何东西 ⇒ 门禁必须绿 ==="
run_swift_gate; rc=$?
[ $rc -eq 0 ] && ok 0 "基准：门禁绿 ✅" || { ok 1 "基准：门禁**不绿**（改之前就红 ⇒ 先修基准）"; tail -10 "$TMP/m$$/out.txt" 2>/dev/null; }

echo "=== ① 双写整个不调用（退回「只写站方变量」⇒ 新版站方源读不到 token）==="
python3 - <<'PYMUT'
p = "QiReaderLite/Core/SourceVariables.swift"
s = open(p, encoding="utf-8").read()
old = """    static func mirrorCredentialToVars(_ value: String, for sourceUrl: String, jsLib: String? = nil) {
        guard !sourceUrl.isEmpty else { return }"""
new = """    static func mirrorCredentialToVars(_ value: String, for sourceUrl: String, jsLib: String? = nil) {
        // （变异：双写整个不做）
        return
        guard !sourceUrl.isEmpty else { return }"""
assert old in s, "锚点没找到（代码形状变了？）"
open(p, "w", encoding="utf-8").write(s.replace(old, new))
PYMUT
run_swift_gate; rc=$?
[ $rc -ne 0 ] && ok 0 "双写不调用 ⇒ 门禁变红 ✅" || { ok 1 "双写不调用 ⇒ 门禁**没红**（门禁没牙齿！）"; tail -12 "$TMP/m$$/out.txt" 2>/dev/null; }
restore

echo "=== ② 双写不挡第②道守卫（形态证据 = map ⇒ 场景 B ⇒ 该挡）==="
python3 - <<'PYMUT'
p = "QiReaderLite/Core/SourceVariables.swift"
s = open(p, encoding="utf-8").read()
old = """        guard form(for: sourceUrl, jsLib: jsLib) != .map else { return }"""
new = """        // （变异：不看形态证据）"""
assert old in s, "锚点没找到（代码形状变了？）"
open(p, "w", encoding="utf-8").write(s.replace(old, new))
PYMUT
run_swift_gate; rc=$?
[ $rc -ne 0 ] && ok 0 "双写不看形态证据 ⇒ 门禁变红 ✅" || { ok 1 "双写不看形态证据 ⇒ 门禁**没红**（门禁没牙齿！）"; tail -12 "$TMP/m$$/out.txt" 2>/dev/null; }
restore

echo "=== ②之二 双写不挡第①道守卫（值本身是 JSON map ⇒ 场景 A ⇒ 该挡）==="
python3 - <<'PYMUT'
p = "QiReaderLite/Core/SourceVariables.swift"
s = open(p, encoding="utf-8").read()
old = """        guard !isMapStyleVariable(t) else { return }"""
new = """        // （变异：不看值是不是 JSON map）"""
assert old in s, "锚点没找到（代码形状变了？）"
open(p, "w", encoding="utf-8").write(s.replace(old, new))
PYMUT
run_swift_gate; rc=$?
[ $rc -ne 0 ] && ok 0 "双写不看值是不是 map ⇒ 门禁变红 ✅" || { ok 1 "双写不看值是不是 map ⇒ 门禁**没红**（门禁没牙齿！）"; tail -12 "$TMP/m$$/out.txt" 2>/dev/null; }
restore

echo "=== ③ 双写覆盖站方自己写的 token（⇒ 把站方的值冲掉）==="
python3 - <<'PYMUT'
p = "QiReaderLite/Core/SourceVariables.swift"
s = open(p, encoding="utf-8").read()
old = """        if let cur = varsMap(for: sourceUrl)["token"], !cur.isEmpty, cur != t { return }"""
new = """        // （变异：不管站方自己写没写，直接覆盖）"""
assert old in s, "锚点没找到（代码形状变了？）"
open(p, "w", encoding="utf-8").write(s.replace(old, new))
PYMUT
run_swift_gate; rc=$?
[ $rc -ne 0 ] && ok 0 "双写覆盖站方的 token ⇒ 门禁变红 ✅" || { ok 1 "双写覆盖站方的 token ⇒ 门禁**没红**（门禁没牙齿！）"; tail -12 "$TMP/m$$/out.txt" 2>/dev/null; }
restore

echo "=== ④ 复原后门禁必须恢复绿 ==="
run_swift_gate; rc=$?
[ $rc -eq 0 ] && ok 0 "复原后门禁恢复绿 ✅" || { ok 1 "复原后门禁还是红 ⇒ 脚本把文件改坏了！"; tail -12 "$TMP/m$$/out.txt" 2>/dev/null; }

echo ""
echo "$( [ $fail -eq 0 ] && echo "✅" || echo "❌" ) 变异测试：通过 $pass / 失败 $fail"
exit $fail
