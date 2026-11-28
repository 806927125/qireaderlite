#!/usr/bin/env bash
# ============================================================
# ⭐⭐⭐⭐⭐ **变异测试**：阅读器启动链的门禁必须抓得住「必崩写法」**（2026-11-28）
#
# 跑法：bash test/mutation-reader-launch-hardening.sh
#
# ⚠️⚠️⚠️ **为什么要有这个** ⭐⭐⭐：
#   真机：「点开始阅读」闪退（文字书/漫画书都崩）⇒ 但 .ips 不好取 ⇒
#   ⇒ 只能靠**代码侧消除必崩写法** + 门禁钉住 ⇒
#   ⇒ **门禁若没牙齿，改回去就等于没修** ⇒ 必须证明它能红 ⭐⭐⭐
# ============================================================
set -uo pipefail
cd "$(dirname "$0")/.."

GATE="test/reader-launch-hardening.test.js"
VOICE="LegadoEngine/Sources/ChaiyueReader/LocalVoiceStore.swift"
HOST="QiReaderLite/Features/Reader/Chaiyue/ChaiyueReaderHost.swift"

TMP="$(mktemp -d)"
cp "$VOICE" "$TMP/voice.bak"
cp "$HOST" "$TMP/host.bak"
restore() { cp "$TMP/voice.bak" "$VOICE"; cp "$TMP/host.bak" "$HOST"; }
trap 'restore; rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { if [ "$1" = "0" ]; then pass=$((pass+1)); echo "  ✓ $2"; else fail=$((fail+1)); echo "  ✗ $2"; fi; }

echo "=== 变异测试：阅读器启动链门禁必须抓得住「必崩写法」 ==="

echo "▶ [①] 基线（未变异）"
if node "$GATE" > "$TMP/base.txt" 2>&1; then
  ok 0 "基线：门禁通过"
else
  ok 1 "基线：门禁本来就不绿（先修好再来做变异）"
  tail -20 "$TMP/base.txt" | sed 's/^/     /'
  echo "通过 $pass / 失败 $fail"; exit 1
fi

echo "▶ [②] 变异 A：目录改回强下标（空数组 ⇒ 越界崩）"
python3 - <<'PY'
p = "LegadoEngine/Sources/ChaiyueReader/LocalVoiceStore.swift"
s = open(p).read()
old = """let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory"""
new = """let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]"""
assert old in s, "没找到 directory 的实现（变异脚本与代码不同步）"
open(p, "w").write(s.replace(old, new))
print("     （已改回 [0]）")
PY
if node "$GATE" > "$TMP/mutA.txt" 2>&1; then
  ok 1 "⭐⭐⭐ **变异后门禁还是绿的 ⇒ 门禁没牙齿（假绿）**"
else
  ok 0 "⭐ 变异后门禁红了 ⇒ 「目录不许强下标」被钉住"
  grep -E "✗" "$TMP/mutA.txt" | head -2 | sed 's/^/     /'
fi
restore

echo "▶ [③] 变异 B：connect() 去掉「没有计划就不建会话」的守卫"
python3 - <<'PY'
p = "LegadoEngine/Sources/ChaiyueReader/LocalVoiceStore.swift"
s = open(p).read()
old = "        guard FileManager.default.fileExists(atPath: Self.planURL.path) else { return }\n"
assert old in s, "没找到 connect() 的守卫（变异脚本与代码不同步）"
open(p, "w").write(s.replace(old, ""))
print("     （已去掉守卫）")
PY
if node "$GATE" > "$TMP/mutB.txt" 2>&1; then
  ok 1 "⭐⭐⭐ **变异后门禁还是绿的 ⇒ 门禁没牙齿（假绿）**"
else
  ok 0 "⭐ 变异后门禁红了 ⇒ 「无计划不许建 background 会话」被钉住"
  grep -E "✗" "$TMP/mutB.txt" | head -2 | sed 's/^/     /'
fi
restore

echo "▶ [④] 变异 C：宿主去掉起始章号的夹紧"
python3 - <<'PY'
p = "QiReaderLite/Features/Reader/Chaiyue/ChaiyueReaderHost.swift"
s = open(p).read()
old = "        if !chapters.indices.contains(startIndex) { startIndex = chapters.isEmpty ? -1 : 0 }\n"
assert old in s, "没找到起始章号的夹紧（变异脚本与代码不同步）"
open(p, "w").write(s.replace(old, ""))
print("     （已去掉夹紧）")
PY
if node "$GATE" > "$TMP/mutC.txt" 2>&1; then
  ok 1 "⭐⭐⭐ **变异后门禁还是绿的 ⇒ 门禁没牙齿（假绿）**"
else
  ok 0 "⭐ 变异后门禁红了 ⇒ 「起始章号必须夹紧」被钉住"
  grep -E "✗" "$TMP/mutC.txt" | head -2 | sed 's/^/     /'
fi
restore

echo "▶ [⑤] 复原后必须恢复绿"
restore
if node "$GATE" > "$TMP/after.txt" 2>&1; then
  ok 0 "复原后门禁恢复绿"
else
  ok 1 "复原后门禁仍红 ⇒ 变异没复原干净"
  tail -20 "$TMP/after.txt" | sed 's/^/     /'
fi

echo
echo "通过 $pass / 失败 $fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
