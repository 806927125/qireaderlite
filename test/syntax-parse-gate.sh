#!/usr/bin/env bash
# ============================================================
# ⭐⭐⭐⭐⭐ **沙盒语法门禁：把 App 源码【每个文件】都 parse 一遍** ⭐⭐⭐⭐⭐
#
# ⚠️⚠️⚠️ **为什么必须有这条**（2026-11-25 build322 实证）⭐⭐⭐：
#   我用脚本给 16 套配色加 `skin:` 参数 ⇒ **括号剥错** ⇒ `skin:` 插进了 `Color(...)` 里面
#   ⇒ ⇒ **语法错** ⇒ 我推了 CI ⇒ **CI 编译失败**（白等一轮 20 分钟）⭐⭐⭐
#   ⇒ ⇒ 而 `swiftc -parse` **只查语法、不需要 SwiftUI/UIKit** ⇒ **Linux 上就能查** ⭐⭐⭐
#   ⇒ ⇒ ⇒ 这类错**本来就该在沙盒 3 秒抓到** ⇒ ⇒ 现在它有门禁了 ⭐⭐⭐⭐⭐
#
# ⭐⭐⭐ **注意它抓不到什么**（别误以为它万能）⭐⭐⭐：
#   · **类型错 / 参数标签错 / 作用域错** ⇒ 只有 Xcode 编译抓得到（`swiftc -parse` 只看语法）⭐⭐⭐
#   · 但**语法错**（括号不配对 / 字符串没闭合 / 关键字写错）⇒ **它全抓得到** ⭐⭐⭐
#   ⇒ ⇒ **CI 仍要跑**（它是唯一能验类型的东西）⇒ ⇒ 但**语法错不该再跑到 CI 才发现** ⭐⭐⭐
# ============================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

SWIFTC=""
for c in "${SWIFT:-}/usr/bin/swiftc" /workspace/.toolchain/swift/usr/bin/swiftc \
         /workspace/.toolchain/swift-6.3-RELEASE-ubuntu22.04/usr/bin/swiftc \
         /usr/bin/swiftc /usr/local/bin/swiftc; do
  [ -n "$c" ] && [ -x "$c" ] && { SWIFTC="$c"; break; }
done
if [ -z "$SWIFTC" ]; then
  echo "⚠️ 跳过：没找到 swiftc（沙盒语法门禁跑不了）"
  exit 0
fi

echo "=== 沙盒语法门禁：swiftc -parse 全量 App 源码 ==="
echo "    swiftc: $SWIFTC"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 找出所有 App 源码（App/ + Features/ + Core/）
mapfile -t FILES < <(find QiReaderLite -name '*.swift' | sort)
echo "    文件数：${#FILES[@]}"

# ⭐ 并行跑（`-P 8`）：串行 36 秒 ⇒ 并行 7 秒 ⭐
printf '%s\n' "${FILES[@]}" | xargs -P 8 -I{} sh -c '
  f="{}"
  out=$("'"$SWIFTC"'" -parse "$f" 2>&1)
  if echo "$out" | grep -q "error:"; then
    echo "FILE:$f"
    echo "$out" | grep -m 5 "error:" | sed "s/^/  /"
  fi
' > "$TMP/out.txt" 2>&1

BAD="$(grep -c '^FILE:' "$TMP/out.txt" || true)"
if [ "$BAD" -gt 0 ]; then
  echo ""
  echo "❌ $BAD 个文件**语法错**（这类错本来该在沙盒抓 ⇒ 不要跑到 CI 才发现）⭐⭐⭐"
  echo ""
  cat "$TMP/out.txt" | head -60
  exit 1
fi

echo "✅ 全部 ${#FILES[@]} 个文件语法 OK（0 错）"
exit 0
