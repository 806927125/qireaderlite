#!/usr/bin/env bash
# ============================================================
# ⭐⭐⭐⭐⭐ **变异测试**：登录页门禁必须抓得住「把 init 挪回 extension」与「删掉 running」（2026-11-27）
#
# 跑法：bash test/mutation-chaiyue-login-init.sh
#
# ⚠️⚠️⚠️ **为什么要有这个** ⭐⭐⭐：
#   CI335/336 连续两轮红，两轮的根因都是**同一条 Swift 语言规则**：
#     · `LoginRow` 有自定义 `init(from:)` ⇒ memberwise init 被抑制
#     ⇒ **extension 里的 init 不能给存储属性赋值** ⇒ 编译报
#        「'self' used before 'self.init' call」⭐⭐⭐
#     ⇒ 而且 `ChaiyueLoginForm.swift` 里 `running` / `run(...)` **被调用但没定义**
#        ⇒ 「cannot find 'running' in scope」⭐⭐⭐
#   ⇒ 这两类错**光看源码看不出来**（语法对、类型也对）⇒ **必须靠门禁钉死** ⭐⭐⭐
#
# ⭐⭐⭐ **本门禁证明那两条断言真的有效**：
#   变异 ⇒ 门禁**必须红** ⇒ 复原 ⇒ 必须绿 ⭐⭐⭐
#   （否则「门禁写了」只是我以为写了 ⇒ 同样的坑下次照踩）⭐⭐⭐
# ============================================================
set -uo pipefail
cd "$(dirname "$0")/.."

GATE="test/reader-chaiyue-login.test.js"
WEBBOOK="LegadoEngine/Sources/ChaiyueEngine/Engine/WebBook.swift"
FORM="LegadoEngine/Sources/ChaiyueReader/ChaiyueLoginForm.swift"
OLD_EXT="LegadoEngine/Sources/LegadoEngine/LoginRow+PublicInit.swift"

[ -f "$GATE" ] || { echo "⚠️ 跳过：找不到 $GATE"; exit 0; }

TMP="$(mktemp -d)"
BAK_WEB="$TMP/WebBook.swift.bak"
BAK_FORM="$TMP/ChaiyueLoginForm.swift.bak"
cp "$WEBBOOK" "$BAK_WEB"
cp "$FORM" "$BAK_FORM"
restore() {
  cp "$BAK_WEB" "$WEBBOOK"
  cp "$BAK_FORM" "$FORM"
  rm -f "$OLD_EXT"
}
trap 'restore; rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { if [ "$1" = "0" ]; then pass=$((pass+1)); echo "  ✓ $2"; else fail=$((fail+1)); echo "  ✗ $2"; fi; }

echo "=== 变异测试：登录页门禁必须抓得住两类「编译期才炸」的错 ==="

# ── ① 基线：门禁本身是绿的 ─────────────────────────────────────
echo "▶ [①] 基线（未变异）"
if node "$GATE" > "$TMP/base.txt" 2>&1; then
  ok 0 "基线：门禁通过"
else
  ok 1 "基线：门禁本来就不绿（先修好再来做变异）"
  tail -25 "$TMP/base.txt" | sed 's/^/     /'
  echo "通过 $pass / 失败 $fail"
  exit 1
fi

# ── ② 变异 A：把 init 挪回 extension（就是 CI336 的那个错）──────
echo "▶ [②] 变异 A：把 public init 挪进 extension（CI336 实锤的写法）"
python3 - "$WEBBOOK" <<'PY'
import re, sys
p = sys.argv[1]
src = open(p).read()
# 把主声明里的 public init 整段抠出来
m = re.search(r"\n    public init\(name: String,.*?\n    \}\n", src, re.S)
assert m, "没找到主声明里的 init（变异脚本与代码不同步）"
init = m.group(0)
src = src[:m.start()] + "\n" + src[m.end():]
# 塞成 extension（= Swift 禁止给存储属性赋值的那种写法）
ext = ("\npublic extension LoginRow {\n"
       + init.replace("\n    public init", "\n    public init").replace("\n        ", "\n        ")
       + "}\n")
src = src.rstrip() + "\n" + ext
open(p, "w").write(src)
print("     （已把 init 挪进 extension）")
PY
if node "$GATE" > "$TMP/mutA.txt" 2>&1; then
  ok 1 "⭐⭐⭐ **变异后门禁居然还是绿的 ⇒ 门禁没有牙齿（假绿）**"
  tail -20 "$TMP/mutA.txt" | sed 's/^/     /'
else
  ok 0 "⭐ 变异后门禁**红了** ⇒ 「init 不许放 extension」这条被钉住了"
  grep -E "✗" "$TMP/mutA.txt" | head -4 | sed 's/^/     /'
fi
restore

# ── ③ 变异 B：删掉 running（就是「cannot find 'running' in scope」）──
echo "▶ [③] 变异 B：删掉 running 的定义"
python3 - "$FORM" <<'PY'
import re, sys
p = sys.argv[1]
src = open(p).read()
m = re.search(r"\n    private var running: Int\? \{.*?\n    \}\n", src, re.S)
assert m, "没找到 running 定义（变异脚本与代码不同步）"
src = src[:m.start()] + "\n" + src[m.end():]
open(p, "w").write(src)
print("     （已删掉 running）")
PY
if node "$GATE" > "$TMP/mutB.txt" 2>&1; then
  ok 1 "⭐⭐⭐ **变异后门禁居然还是绿的 ⇒ 门禁没有牙齿（假绿）**"
  tail -20 "$TMP/mutB.txt" | sed 's/^/     /'
else
  ok 0 "⭐ 变异后门禁**红了** ⇒ 「running 必须存在」这条被钉住了"
  grep -E "✗" "$TMP/mutB.txt" | head -4 | sed 's/^/     /'
fi
restore

# ── ④ 变异 C：把表单键换成显示名（真机上的登录失败根因）───────
echo "▶ [④] 变异 C：让求值后的显示名顶掉技术名（表单键被污染）"
BAK_HOST="$TMP/SourceLoginSheet.swift.bak"
cp QiReaderLite/Features/Sources/SourceLoginSheet.swift "$BAK_HOST"
python3 - <<'PY'
p = "QiReaderLite/Features/Sources/SourceLoginSheet.swift"
src = open(p).read()
old = "return d.isEmpty ? f : Field(name: f.name, displayName: d,"
new = "return d.isEmpty ? f : Field(name: d, displayName: d,"
assert old in src, "没找到 viewName 回填那一行（变异脚本与代码不同步）"
open(p, "w").write(src.replace(old, new))
print("     （已让显示名顶掉技术名）")
PY
if node "$GATE" > "$TMP/mutC.txt" 2>&1; then
  ok 1 "⭐⭐⭐ **变异后门禁居然还是绿的 ⇒ 门禁没有牙齿（假绿）**"
  tail -20 "$TMP/mutC.txt" | sed 's/^/     /'
else
  ok 0 "⭐ 变异后门禁**红了** ⇒ 「表单键必须是技术名」这条被钉住了"
  grep -E "✗" "$TMP/mutC.txt" | head -4 | sed 's/^/     /'
fi
cp "$BAK_HOST" QiReaderLite/Features/Sources/SourceLoginSheet.swift

# ── ⑤ 复原后必须恢复绿 ───────────────────────────────────────
echo "▶ [⑤] 复原后必须恢复绿"
restore
if node "$GATE" > "$TMP/after.txt" 2>&1; then
  ok 0 "复原后门禁恢复绿"
else
  ok 1 "复原后门禁仍红 ⇒ 变异没复原干净"
  tail -25 "$TMP/after.txt" | sed 's/^/     /'
fi

echo
echo "通过 $pass / 失败 $fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
