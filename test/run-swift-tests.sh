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
# ⚠️ 沙盒下 swiftc 是**动态链**的：libswiftCore.so 在 /tmp/swift/usr/lib/swift/linux
#    不设这个环境变量 → `error while loading shared libraries: libswiftCore.so`
if [ -d /tmp/swift/usr/lib/swift/linux ]; then
  export LD_LIBRARY_PATH="/tmp/swift/usr/lib/swift/linux:${LD_LIBRARY_PATH:-}"
fi
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

# ── 第二组：URL 规则（Core/AnalyzeUrl.swift）─────────────────
# ⚠️ 栖阅的 URL 规则是**原生 Swift**；轻阅原来放 JS → 沙盒和真机两套实现 → 栽过两次。
#    放 Core/ 就是为了沙盒 swiftc 能真编真跑。
echo
echo "=== 编译 Core/AnalyzeUrl.swift（swiftc 真编）==="
# ⚠️ 入口文件**必须叫 main.swift**（Swift 顶层代码限制）→ 单独一个目录
mkdir -p "$TMP/url"
cp test/analyze-url-test.swift "$TMP/url/main.swift"
if ! "$SWIFTC" -O "$TMP/url/main.swift" QiReaderLite/Core/AnalyzeUrl.swift -o "$TMP/url-test" 2>"$TMP/err2.txt"; then
  echo "❌ 编译失败："
  cat "$TMP/err2.txt" | head -30
  exit 1
fi
echo "✓ 编译通过"
echo
"$TMP/url-test"
rc2=$?
[ $rc2 -ne 0 ] && rc=$rc2
exit $rc
