#!/usr/bin/env bash
# ============================================================
# 轻阅原生层（Core/ 纯 Foundation）的**真跑**测试
#
# 跑法：bash test/run-swift-tests.sh
#
# 为什么要有这个：`Core/` 是纯 Foundation 层（不 import WebKit/SwiftUI）→
# 在 Linux 沙盒里能真编真跑 → 改完 3 秒出结果，不用等 CI。
# 这也是「引擎能力一律用 Swift 写」能落地的**前提**：
# 能力写在 Swift 里，就得能在沙盒里验。
#
# 依赖：Swift toolchain（沙盒里下到 /tmp/swift，或用系统 swiftc）
# ============================================================
set -uo pipefail
cd "$(dirname "$0")/.."

SWIFTC=""
for c in /tmp/swift/usr/bin/swiftc "$(command -v swiftc || true)"; do
  [ -x "$c" ] && { SWIFTC="$c"; break; }
done
if [ -z "$SWIFTC" ]; then
  echo "⚠️  没找到 swiftc → 跳过 Swift 原生层测试"
  echo "   （沙盒里下工具链：https://download.swift.org/swift-6.1.2-release/debian12/swift-6.1.2-RELEASE/swift-6.1.2-RELEASE-debian12.tar.gz）"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ⚠️ swiftc 编译多个文件时，入口文件必须叫 main.swift（顶层代码限制）
cp test/legado-compat-test.swift "$TMP/main.swift"

echo "=== 编译 Core/LegadoCompat.swift（swiftc 真编）==="
if ! "$SWIFTC" -O "$TMP/main.swift" QiReaderLite/Core/LegadoCompat.swift -o "$TMP/compat-test" 2>"$TMP/err.txt"; then
  echo "❌ 编译失败："
  cat "$TMP/err.txt" | head -30
  exit 1
fi
echo "✓ 编译通过"

echo
"$TMP/compat-test"
rc=$?
exit $rc
