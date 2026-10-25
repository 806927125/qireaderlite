#!/usr/bin/env bash
# ============================================================
# ⭐⭐⭐ **真实源链路自检** —— 新引擎（Swift）单跑
#
# ⚠️⚠️ **2026-10-25：老引擎已物理删除** ⇒ 本脚本原来做的「老引擎 vs 新引擎」对拍
#   **无法再做**（老的那一半没了）⭐⭐⭐
# ⇒ 现在它做的是：**新引擎把真实源的整条链路跑一遍**（分类→发现→详情→目录→正文）
#   ⇒ 每一步的「数量 / 错误」都打出来 ⇒ **一眼看出哪一步断了** ⭐⭐⭐
# ⇒ **对拍能力没丢**：迁到了【引擎仓】的
#   `Tests/LegadoCoreTests/StationDahulangChainParityTests.swift`
#   （那边有老引擎的 Node 参考实现 + 真实响应 fixture）⭐⭐⭐
#
# 用法：bash test/live-parity.sh <pack.json> [源名关键字]
# ⚠️ 需要：node、本地已编译的 legado-engine（LegadoCore 模块）
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

echo "▶ 新引擎（Swift）…"
NEW=$("$TMP/new-live" "$PACK" "$KEYWORD" 2>/dev/null | tail -1)
echo "  $NEW"

echo
echo "=== 链路自检 ==="
python3 - "$NEW" <<'PY'
import json, sys
try:
    new = json.loads(sys.argv[1])
except Exception as e:
    print("  ⚠️ 解析失败：", e); sys.exit(0)
steps = new.get('steps', {})
bad = 0
for s in sorted(steps):
    v = steps[s]
    err = v.get('error') if isinstance(v, dict) else None
    if err:
        bad += 1
        print(f"  ❌ {s}: {err}")
    else:
        print(f"  ✅ {s}: {json.dumps(v, ensure_ascii=False)}")
print()
print(f"  ⇒ {len(steps)} 步，{bad} 步有错")
if bad:
    print("  ⇒ ⚠️ **有断点** ⇒ 上面标 ❌ 的那一步就是断的")
PY
