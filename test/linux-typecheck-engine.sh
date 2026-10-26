#!/bin/bash
# ============================================================
# ⭐ **新引擎适配层**的 Linux 真类型检查
#
# 验的是：`QiReaderLite/Core/LegadoEngineBackend.swift`
#      （老 JS 引擎 → 自研 Swift 引擎的适配层：模型转换 + 传输 + op 映射）
#
# 为什么单独一条：
#   · 完整 Foundation 层门禁（linux-typecheck.sh）依赖 WebKit/UIKit/SwiftUI 的 shim，
#     而那份 shim 跟不上 RuleSandbox 的演进 ⇒ 已知红
#   · 而适配层是这轮**最需要真类型检查**的地方（它把两个模型的字段名一一对上）
#   ⇒ 给它一条**独立、能跑**的通道 ⇒ 3 秒抓错，不用等 CI ⭐
#
# 依赖：本地已编译的 legado-engine（`swift build` ⇒ .build/debug/Modules/LegadoCore.swiftmodule）
# ============================================================
set -uo pipefail
cd "$(dirname "$0")/.."

SWIFTC=""
for c in /tmp/swift/usr/bin/swiftc \
         "$(dirname "$(dirname "$0")")/../.toolchain/swift/usr/bin/swiftc" \
         "$(command -v swiftc || true)"; do
  [ -x "$c" ] && { SWIFTC="$c"; break; }
done
if [ -z "$SWIFTC" ]; then
  echo "⚠️  没找到 swiftc ⇒ 跳过（新引擎适配层的类型检查没跑）"
  exit 0
fi
if [ -d /tmp/swift/usr/lib/swift/linux ]; then
  export LD_LIBRARY_PATH="/tmp/swift/usr/lib/swift/linux:${LD_LIBRARY_PATH:-}"
fi

LEGADO_MODULES="${LEGADO_MODULES:-../legado-engine/.build/debug/Modules}"
if [ ! -f "$LEGADO_MODULES/LegadoCore.swiftmodule" ]; then
  echo "⚠️  没找到 LegadoCore 模块（$LEGADO_MODULES）"
  echo "   ⇒ 先在 ../legado-engine 跑一次：swift build"
  echo "   ⇒ 跳过（新引擎适配层的类型检查没跑）"
  exit 0
fi

echo "▶ 工具链: $("$SWIFTC" --version 2>/dev/null | head -1)"
echo "▶ LegadoCore: $LEGADO_MODULES"

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

"$SWIFTC" -typecheck -swift-version 5 -strict-concurrency=minimal \
  -I "$LEGADO_MODULES" \
  test/linux-shims/CombineShim.swift \
  test/linux-shims/EngineBackendStubs.swift \
  test/linux-shims/FoundationCookieShim.swift \
  QiReaderLite/Core/BookSource.swift \
  QiReaderLite/Core/Book.swift \
  QiReaderLite/Core/SourceVariables.swift \
  QiReaderLite/Core/EngineBackend.swift \
  QiReaderLite/Core/LegadoEngineBackend.swift \
  QiReaderLite/Core/JSEngineFactory.swift \
  QiReaderLite/Core/SourceService.swift \
  QiReaderLite/Core/ServiceError.swift \
  QiReaderLite/Core/SourceDictCache.swift \
  QiReaderLite/Core/SourceRawArchive.swift \
  QiReaderLite/Core/AppPaths.swift \
  QiReaderLite/Core/HostTools.swift \
  QiReaderLite/Core/MemoryMeter.swift \
  QiReaderLite/Core/LRUKeys.swift \
  2>&1 | tee "$OUT/log.txt"

ERRS=$(grep -c "error:" "$OUT/log.txt" || true)
echo ""
if [ "$ERRS" -gt 0 ]; then
  echo "❌ $ERRS 个错误"
  grep -n "error:" "$OUT/log.txt" | sed 's/^/  /' | head -40
  exit 1
fi
echo "✅ 新引擎适配层类型检查通过（0 错误）"
