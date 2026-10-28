#!/usr/bin/env bash
# ============================================================
# ⭐⭐⭐⭐⭐ **变异测试**：把实现改坏 ⇒ 门禁必须红
#
# 跑法：bash test/mutation-station-var.sh
#
# 为什么要有这个门禁：
#   门禁「全绿」有两种可能：① 实现对 ② **门禁没抓到东西**（平凡通过）⭐⭐⭐
#   ⇒ 所以每个断言都要问「**把实现改坏，它会不会红**」⭐
#   ⇒ 这个脚本就是把实现改坏 N 次，看门禁是不是每次都红 ⭐⭐⭐
#
# ⚠️ **复原用「拷副本」**，不用 `git checkout` ⇒ 不会冲掉未提交的改动（踩过）⭐
# ⚠️ **改坏的锚点必须跟当前代码形状一致** ⇒ 代码一改，锚点要跟着改（否则「变异没生效」
#    ⇒ 门禁当然不红 ⇒ **看起来像门禁没牙齿，其实是变异没打中**）⭐⭐⭐
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
SVC="QiReaderLite/Core/SourceService.swift"
BACK="QiReaderLite/Core/LegadoEngineBackend.swift"
EXEC="QiReaderLite/Engine/WebViewJSExecutor.swift"
ANALYZE="QiReaderLite/Core/AnalyzeUrl.swift"

BAK="$TMP/backup"; mkdir -p "$BAK"
cp "$VARS" "$BAK/vars.swift"; cp "$SVC" "$BAK/svc.swift"
cp "$BACK" "$BAK/back.swift"; cp "$FORM" "$BAK/form.swift"
cp "$EXEC" "$BAK/exec.swift"; cp "$ANALYZE" "$BAK/analyze.swift"
restore() {
  cp "$BAK/vars.swift" "$VARS"; cp "$BAK/svc.swift" "$SVC"
  cp "$BAK/back.swift" "$BACK"; cp "$BAK/form.swift" "$FORM"
  cp "$BAK/exec.swift" "$EXEC"; cp "$BAK/analyze.swift" "$ANALYZE"
}
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
  (cd "$(dirname "$0")/.." && "$dir/t" > "$dir/out.txt" 2>&1)
  return $?
}

# 跑「站方变量感知 source」的接线门禁（Node ⇒ 秒级）
run_bridge_gate() {
  node test/station-var-bridge.test.js > "$TMP/bridge.txt" 2>&1
  return $?
}

# 跑「JSON 列表项改写 + 带后缀图片 URL」的接线门禁（Node ⇒ 秒级）
run_rewrite_gate() {
  node test/toc-jsonpath-rewrite.test.js > "$TMP/rewrite.txt" 2>&1
  return $?
}

echo "=== ① 回传恒当「站方写的」证据（自证） ==="
python3 - <<'PY'
p = "QiReaderLite/Core/SourceService.swift"
s = open(p, encoding="utf-8").read()
old = "origin: Self.stationWroteIt(obj) ? .station : .app"
assert old in s, "锚点没找到（代码形状变了？）"
open(p, "w", encoding="utf-8").write(s.replace(old, "origin: .station"))
PY
node test/source-variable-shape.test.js > "$TMP/js1.txt" 2>&1
[ $? -ne 0 ] && ok 0 "回传恒当证据 ⇒ source-variable-shape 变红 ✅" || { ok 1 "回传恒当证据 ⇒ 门禁**没红**"; tail -6 "$TMP/js1.txt"; }
restore

echo "=== ② 证据的键不带版本（旧的污染证据继续生效） ==="
python3 - <<'PY'
p = "QiReaderLite/Core/SourceVariables.swift"
s = open(p, encoding="utf-8").read()
old = "sourcevariable.stationform.v2."
assert old in s, "锚点没找到"
open(p, "w", encoding="utf-8").write(s.replace(old, "sourcevariable.stationform."))
PY
node test/source-variable-shape.test.js > "$TMP/js2.txt" 2>&1
[ $? -ne 0 ] && ok 0 "证据键去掉版本 ⇒ 变红 ✅" || { ok 1 "证据键去掉版本 ⇒ 门禁**没红**"; tail -6 "$TMP/js2.txt"; }
restore

echo "=== ③ 污染迁移挂在走不到的链上 ==="
python3 - <<'PY'
p = "QiReaderLite/Core/SourceService.swift"
s = open(p, encoding="utf-8").read()
old = "SourceVariables.stationVariableToSeed(for: source.bookSourceUrl, jsLib: source.jsLib)"
assert old in s, "锚点没找到"
open(p, "w", encoding="utf-8").write(s.replace(old, "SourceVariables.variable(for: source.bookSourceUrl)"))
PY
node test/source-variable-shape.test.js > "$TMP/js3.txt" 2>&1
[ $? -ne 0 ] && ok 0 "迁移被绕开 ⇒ 变红 ✅" || { ok 1 "迁移被绕开 ⇒ 门禁**没红**"; tail -6 "$TMP/js3.txt"; }
restore

echo "=== ④ 引擎不报「站方改没改」 ==="
python3 - <<'PY'
p = "QiReaderLite/Core/LegadoEngineBackend.swift"
s = open(p, encoding="utf-8").read()
old = 'dict["__sourceVariableChanged"] = (sv.text != (seededStationVariable ?? ""))'
assert old in s, "锚点没找到"
open(p, "w", encoding="utf-8").write(s.replace(old, 'dict["__sourceVariableChanged"] = true'))
PY
node test/source-variable-shape.test.js > "$TMP/js4.txt" 2>&1
[ $? -ne 0 ] && ok 0 "引擎恒报「改过」⇒ 变红 ✅" || { ok 1 "引擎恒报「改过」⇒ 门禁**没红**"; tail -6 "$TMP/js4.txt"; }
restore

echo "=== ⑤ 静态扫描：凭据优先（会误伤大灰狼的线路表） ==="
python3 - <<'PY'
p = "QiReaderLite/Core/StationVarForm.swift"
s = open(p, encoding="utf-8").read()
old = """        if sawMap { return .map }
        if sawCredential { return .credential }"""
new = """        if sawCredential { return .credential }
        if sawMap { return .map }"""
assert old in s, "锚点没找到"
open(p, "w", encoding="utf-8").write(s.replace(old, new))
PY
run_swift_gate; rc=$?
[ $rc -ne 0 ] && ok 0 "凭据优先（大灰狼被误判）⇒ Swift 门禁变红 ✅" || { ok 1 "凭据优先 ⇒ 门禁**没红**"; tail -14 "$TMP/m$$/out.txt" 2>/dev/null; }
restore

echo "=== ⑥ 静态扫描：不认 getArguments（大灰狼判成凭据） ==="
python3 - <<'PY'
p = "QiReaderLite/Core/StationVarForm.swift"
s = open(p, encoding="utf-8").read()
old = 'call.stack.contains(where: { $0 == "JSON.parse" || $0 == "getArguments" })'
new = 'call.stack.contains(where: { $0 == "JSON.parse" })'
assert old in s, "锚点没找到"
open(p, "w", encoding="utf-8").write(s.replace(old, new))
PY
run_swift_gate; rc=$?
[ $rc -ne 0 ] && ok 0 "扫描器不认 getArguments ⇒ Swift 门禁变红 ✅" || { ok 1 "扫描器不认 getArguments ⇒ 门禁**没红**"; tail -14 "$TMP/m$$/out.txt" 2>/dev/null; }
restore

echo "=== ⑦ 清污染的逻辑删掉（污染留着 ⇒ 403 无效JWT） ==="
python3 - <<'PY'
p = "QiReaderLite/Core/SourceVariables.swift"
s = open(p, encoding="utf-8").read()
old = """        setVariable("", for: sourceUrl, origin: .app)
        return \"\""""
new = """        return \"\""""
assert old in s, "锚点没找到"
open(p, "w", encoding="utf-8").write(s.replace(old, new))
PY
run_swift_gate; rc=$?
[ $rc -ne 0 ] && ok 0 "清污染逻辑删掉 ⇒ Swift 门禁变红 ✅" || { ok 1 "清污染逻辑删掉 ⇒ 门禁**没红**"; tail -14 "$TMP/m$$/out.txt" 2>/dev/null; }
restore

echo "=== ⑧ 宿主写 map 的凭据拦截删掉（UAA 又被塞 map） ==="
python3 - <<'PY'
p = "QiReaderLite/Core/SourceVariables.swift"
s = open(p, encoding="utf-8").read()
old = "guard form(for: sourceUrl, jsLib: jsLib) != .credential else { return }"
new = "guard true else { return }"
assert old in s, "锚点没找到"
open(p, "w", encoding="utf-8").write(s.replace(old, new))
PY
run_swift_gate; rc=$?
[ $rc -ne 0 ] && ok 0 "凭据拦截删掉 ⇒ Swift 门禁变红 ✅" || { ok 1 "凭据拦截删掉 ⇒ 门禁**没红**"; tail -14 "$TMP/m$$/out.txt" 2>/dev/null; }
restore

echo "=== ⑨ 形态判据去掉【静态扫描】（只剩运行时证据） ==="
python3 - <<'PY'
p = "QiReaderLite/Core/SourceVariables.swift"
s = open(p, encoding="utf-8").read()
old = "let staticForm = StationVarFormScanner.form(jsLib: jsLib)"
new = "let staticForm = StationVarForm.unknown"
assert old in s, "锚点没找到"
open(p, "w", encoding="utf-8").write(s.replace(old, new))
PY
run_swift_gate; rc=$?
[ $rc -ne 0 ] && ok 0 "去掉静态扫描 ⇒ Swift 门禁变红 ✅" || { ok 1 "去掉静态扫描 ⇒ 门禁**没红**"; tail -14 "$TMP/m$$/out.txt" 2>/dev/null; }
restore

echo "=== ⑩ 去掉【结构性判据】（站方没写过 ⇒ 宿主灌的 ⇒ 该清） ==="
python3 - <<'PYMUT'
p = "QiReaderLite/Core/SourceVariables.swift"
s = open(p, encoding="utf-8").read()
old = "let isHostPollution = !stationWroteIt"
new = "let isHostPollution = false"
assert old in s, "锚点没找到"
open(p, "w", encoding="utf-8").write(s.replace(old, new))
PYMUT
run_swift_gate; rc=$?
[ $rc -ne 0 ] && ok 0 "去掉结构性判据 ⇒ Swift 门禁变红 ✅" || { ok 1 "去掉结构性判据 ⇒ 门禁**没红**"; tail -14 "$TMP/m$$/out.txt" 2>/dev/null; }
restore

echo "=== ⑪ 复原后门禁必须恢复绿（证明脚本没把文件改坏） ==="
run_swift_gate; rc=$?
[ $rc -eq 0 ] && ok 0 "Swift 门禁恢复绿 ✅" || { ok 1 "Swift 门禁复原后还是红 ⇒ 脚本把文件改坏了！"; grep -E "✗|COMPILE" "$TMP/m$$/out.txt" "$TMP/m$$/err.txt" 2>/dev/null | head -8; tail -6 "$TMP/m$$/err.txt" 2>/dev/null; }
node test/source-variable-shape.test.js > "$TMP/js10.txt" 2>&1
[ $? -eq 0 ] && ok 0 "source-variable-shape 恢复绿 ✅" || ok 1 "source-variable-shape 复原后还是红"
node test/uaa-original-station-var.test.js > "$TMP/js10b.txt" 2>&1
[ $? -eq 0 ] && ok 0 "uaa-original-station-var 恢复绿 ✅" || ok 1 "uaa-original-station-var 复原后还是红"

# ── ⭐⭐⭐⭐⭐ ⑫⑬⑭⑮：**站方变量感知的 source**（2026-10-28 真机 403 的宿主侧兜底）──
#   症状：✿UAA 目录 op 403「无效JWT」⇒ `Bearer {"androidId":"…"}`
#   根因：引擎在 toc/content 里重建 sourceObject 时**漏传站方变量槽**
#   ⇒ 宿主侧包一层（getVariable/setVariable 走槽，其余委托）
#   ⇒ 这三条分别把「槽」「run」「runGlobal」各改坏一次 ⇒ 门禁每次都得红 ⭐⭐⭐
echo "=== ⑫ 宿主那份 source 不用站方变量槽了 ==="
python3 - <<'PY'
p = "QiReaderLite/Core/LegadoEngineBackend.swift"
s = open(p, encoding="utf-8").read()
old = 'methods["getVariable"] = { _ in .string(slot.text) }'
new = 'methods["getVariable"] = { _ in .string("") }'
assert old in s, "锚点没找到（代码形状变了？）"
open(p, "w", encoding="utf-8").write(s.replace(old, new))
PY
run_bridge_gate; rc=$?
[ $rc -ne 0 ] && ok 0 "getVariable 不读槽 ⇒ station-var-bridge 变红 ✅" || { ok 1 "getVariable 不读槽 ⇒ 门禁**没红**"; tail -8 "$TMP/bridge.txt"; }
restore

echo "=== ⑬ run() 里不换 source ==="
python3 - <<'PY'
p = "QiReaderLite/Engine/WebViewJSExecutor.swift"
s = open(p, encoding="utf-8").read()
old = """        currentHostObjects = Self.hostObjects(from: context)
        applyStationVariableSource()"""
new = """        currentHostObjects = Self.hostObjects(from: context)"""
assert old in s, "锚点没找到（代码形状变了？）"
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
run_bridge_gate; rc=$?
[ $rc -ne 0 ] && ok 0 "run() 不换 source ⇒ station-var-bridge 变红 ✅" || { ok 1 "run() 不换 source ⇒ 门禁**没红**"; tail -8 "$TMP/bridge.txt"; }
restore

echo "=== ⑭ runGlobal() 里不换 source ==="
python3 - <<'PY'
p = "QiReaderLite/Engine/WebViewJSExecutor.swift"
s = open(p, encoding="utf-8").read()
old = """        currentHostObjects = Self.hostObjects(from: context)
        applyStationVariableSource()"""
new = """        currentHostObjects = Self.hostObjects(from: context)"""
# ⚠️ run() 和 runGlobal() 这两处**长得一样** ⇒ 改**最后**一处（= runGlobal 的）⭐
idx = s.rfind(old)
assert idx >= 0, "锚点没找到（代码形状变了？）"
s = s[:idx] + new + s[idx + len(old):]
open(p, "w", encoding="utf-8").write(s)
PY
run_bridge_gate; rc=$?
[ $rc -ne 0 ] && ok 0 "runGlobal() 不换 source ⇒ station-var-bridge 变红 ✅" || { ok 1 "runGlobal() 不换 source ⇒ 门禁**没红**"; tail -8 "$TMP/bridge.txt"; }
restore

echo "=== ⑮ 复原后接线门禁必须恢复绿 ==="
run_bridge_gate; rc=$?
[ $rc -eq 0 ] && ok 0 "station-var-bridge 恢复绿 ✅" || { ok 1 "station-var-bridge 复原后还是红 ⇒ 脚本把文件改坏了！"; tail -10 "$TMP/bridge.txt"; }

# ── ⭐⭐⭐⭐⭐ ⑯⑰⑱⑲：**JSON 列表项的字段规则改写 + 带后缀的图片 URL**（2026-10-29）──
#   症状：目录「有行、点得开、就是没标题」；封面全是占位图
echo "=== ⑯ chapterName 不改写成 JSONPath ==="
python3 - <<'PY'
p = "QiReaderLite/Core/LegadoEngineBackend.swift"
s = open(p, encoding="utf-8").read()
old = "            f.chapterName = Self.jsonPathForm(f.chapterName)"
new = "            // f.chapterName = Self.jsonPathForm(f.chapterName)"
assert old in s, "锚点没找到（代码形状变了？）"
open(p, "w", encoding="utf-8").write(s.replace(old, new))
PY
run_rewrite_gate; rc=$?
[ $rc -ne 0 ] && ok 0 "chapterName 不改写 ⇒ toc-jsonpath-rewrite 变红 ✅" || { ok 1 "chapterName 不改写 ⇒ 门禁**没红**"; tail -8 "$TMP/rewrite.txt"; }
restore

echo "=== ⑰ isVolume 改成 JSONPath（JSON 的 false 会变成非空 ⇒ 每章都成卷）==="
python3 - <<'PY'
p = "QiReaderLite/Core/LegadoEngineBackend.swift"
s = open(p, encoding="utf-8").read()
old = "            f.isVolume = nil"
new = "            f.isVolume = Self.jsonPathForm(f.isVolume)"
assert old in s, "锚点没找到（代码形状变了？）"
open(p, "w", encoding="utf-8").write(s.replace(old, new))
PY
run_rewrite_gate; rc=$?
[ $rc -ne 0 ] && ok 0 "isVolume 改写 ⇒ 门禁变红 ✅" || { ok 1 "isVolume 改写 ⇒ 门禁**没红**"; tail -8 "$TMP/rewrite.txt"; }
restore

echo "=== ⑱ 图片 URL 不拆 ,{…} 后缀（⇒ URL(string:) 失败 ⇒ 404）==="
python3 - <<'PY'
p = "QiReaderLite/Core/AnalyzeUrl.swift"
s = open(p, encoding="utf-8").read()
old = "        let (urlPart, opt) = splitOptions(raw.trimmingCharacters(in: .whitespacesAndNewlines))"
new = "        let urlPart = raw.trimmingCharacters(in: .whitespacesAndNewlines)\n        let opt: [String: Any] = [:]"
assert old in s, "锚点没找到（代码形状变了？）"
open(p, "w", encoding="utf-8").write(s.replace(old, new))
PY
run_rewrite_gate; rc=$?
[ $rc -ne 0 ] && ok 0 "不拆后缀 ⇒ 门禁变红 ✅" || { ok 1 "不拆后缀 ⇒ 门禁**没红**"; tail -8 "$TMP/rewrite.txt"; }
restore

echo "=== ⑲ 复原后改写门禁必须恢复绿 ==="
run_rewrite_gate; rc=$?
[ $rc -eq 0 ] && ok 0 "toc-jsonpath-rewrite 恢复绿 ✅" || { ok 1 "toc-jsonpath-rewrite 复原后还是红 ⇒ 脚本把文件改坏了！"; tail -10 "$TMP/rewrite.txt"; }

echo ""
echo "$( [ $fail -eq 0 ] && echo "✅" || echo "❌" ) 变异测试：通过 $pass / 失败 $fail"
exit $fail
