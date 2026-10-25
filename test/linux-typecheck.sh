#!/bin/bash
# 在 Linux 上用 swiftc 真正类型检查 Foundation 层。
# 覆盖：书源模型（Codable 那一堆自定义 init）、书籍模型、存储层、DTO 编解码。
# 覆盖：RuleSandbox（靠 WebKit/UIKit shim，只抓自己代码的错，不保证 WebKit 用法对）。
# 覆盖不到：各 SwiftUI 页面（SwiftUI 的泛型修饰符链没法用假模块验）。
set -uo pipefail

SWIFT_BIN="${SWIFT_BIN:-/opt/swift/swift-6.1.2-RELEASE-debian12/usr/bin/swiftc}"
if [[ ! -x "$SWIFT_BIN" ]]; then
  echo "❌ 找不到 swiftc: $SWIFT_BIN"
  exit 1
fi

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

echo "▶ 工具链: $("$SWIFT_BIN" --version 2>/dev/null | head -1)"

# Linux 上没有 SwiftUI / WebKit / UIKit 模块，把 import 剥掉，用 shim 提供符号
sed 's/^import SwiftUI$//' QiReaderLite/Core/Store.swift > "$OUT/Store.swift"
sed -e 's/^import WebKit$//' -e 's/^import UIKit$//' -e 's/^import SwiftUI$//' \
    -e 's|^import Foundation$|import Foundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif|' \
    QiReaderLite/Core/RuleSandbox.swift > "$OUT/RuleSandbox.swift"

# 阅读界面的桥也要真检查：它是 WebKit 层，Linux 上有 shim，能抓类型错
sed -e 's/^import WebKit$//' -e 's/^import UIKit$//' \
    -e 's|^import Foundation$|import Foundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif|' \
    QiReaderLite/Core/ReaderHost.swift > "$OUT/ReaderHost.swift"

# 阅读会话的接线逻辑也要真检查（纯 Foundation/Combine，不碰 SwiftUI）
sed -e 's/^import Combine$//' \
    -e 's|^import Foundation$|import Foundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif|' \
    QiReaderLite/Core/ReaderSession.swift > "$OUT/ReaderSession.swift"

# ⭐⭐⭐ **新引擎后端**（legado-engine）—— 需要本地已编译的 LegadoCore 模块
#
# ⚠️ 为什么要有这段：老 JS 引擎换成自研 Swift 引擎后，
#    **适配层（模型转换 + 传输 + op 映射）是最容易出类型错的地方**
#    ⇒ 而 iOS 真机构建要等 CI ⇒ 沙盒里能真类型检查 ⇒ 3 秒抓错 ⭐
#
# ⚠️ 本地没编译过 legado-engine ⇒ 这段**跳过**（别让门禁变成假绿）
LEGADO_MODULES="${LEGADO_MODULES:-../legado-engine/.build/debug/Modules}"
EXTRA=()
if [[ -f "$LEGADO_MODULES/LegadoCore.swiftmodule" ]]; then
  echo "▶ 找到 LegadoCore 模块：$LEGADO_MODULES"
  EXTRA=(-I "$LEGADO_MODULES" QiReaderLite/Core/LegadoEngineBackend.swift)
else
  echo "⚠️  没找到 LegadoCore 模块（先在 ../legado-engine 跑 swift build）⇒ 跳过新引擎后端的类型检查"
fi

echo "▶ 类型检查 Foundation 层…"
"$SWIFT_BIN" -typecheck -swift-version 5 \
  test/linux-shims/CombineShim.swift \
  test/linux-shims/WebKitUIKitShim.swift \
  test/linux-shims/URLSessionConfigShim.swift \
  QiReaderLite/Core/BookSource.swift \
  QiReaderLite/Core/Book.swift \
  QiReaderLite/Core/SourceVariables.swift \
  QiReaderLite/Core/EngineBackend.swift \
  QiReaderLite/Core/HostTools.swift \
  "$OUT/Store.swift" \
  QiReaderLite/Core/SourceService.swift \
  "$OUT/RuleSandbox.swift" \
  "$OUT/ReaderHost.swift" \
  "$OUT/ReaderSession.swift" \
  "${EXTRA[@]}" \
  2>&1 | tee "$OUT/log.txt"

ERRS=$(grep -c "error:" "$OUT/log.txt" || true)
WARNS=$(grep -c "warning:" "$OUT/log.txt" || true)

echo ""
if [[ "$ERRS" -gt 0 ]]; then
  echo "❌ $ERRS 个错误"
  echo ""
  echo "--- 错误明细 ---"
  grep -n "error:" "$OUT/log.txt" | sed 's/^/  /'
  exit 1
fi
echo "✅ Foundation 层类型检查通过（0 错误，$WARNS 警告）"
