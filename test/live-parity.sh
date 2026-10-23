#!/usr/bin/env bash
# ============================================================
# ⭐⭐⭐ **真实源双实现对拍** —— 老引擎（Node）vs 新引擎（Swift）
#
# 验的是「老引擎有的、新引擎没有的语义」：
#   同一个源、同一套规则、同一条链路（分类→发现→详情→目录→正文）
#   两边各跑一遍 ⇒ **数字不一样的地方就是差异**⭐
#
# 用法：bash test/live-parity.sh <pack.json> [源名关键字]
# ⚠️ 需要：node（+ jsdom）、本地已编译的 legado-engine（LegadoCore 模块）
# ============================================================
set -uo pipefail
cd "$(dirname "$0")/.."

PACK="${1:-sources/配置文件125个-轻阅适配版.json}"
KEYWORD="${2:-}"

SWIFTC=""
for c in /tmp/swift/usr/bin/swiftc \
         "$(dirname "$(dirname "$0")")/../.toolchain/swift/usr/bin/swiftc" \
         "$(command -v swiftc || true)"; do
  [ -x "$c" ] && { SWIFTC="$c"; break; }
done
if [ -d /tmp/swift/usr/lib/swift/linux ]; then
  export LD_LIBRARY_PATH="/tmp/swift/usr/lib/swift/linux:${LD_LIBRARY_PATH:-}"
fi

LEGADO_MODULES="${LEGADO_MODULES:-../legado-engine/.build/debug/Modules}"
LEGADO_BUILD="${LEGADO_BUILD:-../legado-engine/.build/debug}"

if [ -z "$SWIFTC" ] || [ ! -f "$LEGADO_MODULES/LegadoCore.swiftmodule" ]; then
  echo "⚠️  缺 swiftc 或 LegadoCore 模块 ⇒ 跳过新引擎侧（老引擎侧仍会跑）"
  exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp test/new-engine-live.swift "$TMP/main.swift"
echo "▶ 编译新引擎探针…"
"$SWIFTC" -O -I "$LEGADO_MODULES" \
  "$TMP/main.swift" \
  test/linux-shims/EngineBackendStubs.swift \
  QiReaderLite/Core/BookSource.swift \
  QiReaderLite/Core/SourceVariables.swift \
  QiReaderLite/Core/EngineBackend.swift \
  QiReaderLite/Core/LegadoEngineBackend.swift \
  "$LEGADO_BUILD"/LegadoCore.build/*.o \
  "$LEGADO_BUILD"/SwiftSoup.build/*.o \
  -o "$TMP/new-live" 2>"$TMP/err.txt"
if [ $? -ne 0 ]; then echo "❌ 编译失败："; head -20 "$TMP/err.txt"; exit 1; fi
echo "✓ 编译通过"

echo "▶ 老引擎（Node）…"
OLD=$(node test/old-engine-live.js "$PACK" "$KEYWORD" 2>/dev/null | tail -1)
echo "  $OLD"
echo "▶ 新引擎（Swift）…"
NEW=$("$TMP/new-live" "$PACK" "$KEYWORD" 2>/dev/null | tail -1)
echo "  $NEW"

echo
echo "=== 差异（老 vs 新）==="
python3 - "$OLD" "$NEW" <<'PY'
import json, sys
old = json.loads(sys.argv[1]); new = json.loads(sys.argv[2])
steps = sorted(set(old.get('steps', {})) | set(new.get('steps', {})))
diffs = 0
for s in steps:
    o = old.get('steps', {}).get(s, {})
    n = new.get('steps', {}).get(s, {})
    if o == n:
        print(f"  ✅ {s}: {json.dumps(o, ensure_ascii=False)}")
    else:
        diffs += 1
        print(f"  ❌ {s}:")
        print(f"       老 = {json.dumps(o, ensure_ascii=False)}")
        print(f"       新 = {json.dumps(n, ensure_ascii=False)}")
print(f"\n差异步骤：{diffs} / {len(steps)}")
PY
