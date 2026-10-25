#!/usr/bin/env bash
# ⭐⭐⭐⭐⭐ **Linux 编译门禁：让 App 侧 `Core/` 的关键文件在沙盒里被 swiftc 真编译**
#
# ⚠️⚠️⚠️ **为什么必须有这个**（2026-10-25 build253 CI 失败事故）：
#   我改了 `SourceService.swift`（新增 `withRealTimeout`）⇒ **沙盒门禁全绿**
#   ⇒ 但沙盒的 swift 门禁**根本没编这个文件**（只编 LegadoCompat / AnalyzeUrl / Book …）
#   ⇒ 于是**多了一个 `}`** 也没人发现 ⇒ 推到 CI ⇒ **BUILD FAILED**（白等一轮 CI）⭐⭐⭐
#
# ⇒ 教训：**「门禁全绿」≠「我改的文件被编过」** ⇒ 改完必须问「这个文件在门禁里吗」⭐⭐⭐
#
# ⭐ **stub 原则**：只给**签名**，**不许给实现**
#   ⇒ 这样「多一个 `}`」「类型写错」「方法不存在」「泛型函数里嵌套类型」都会**真编译报错** ⭐⭐⭐
#   ⇒ 一旦给 stub 写实现 ⇒ 变成「用假实现验真代码」⇒ 失去意义 ⇒ 禁止 ⭐
#
# ⭐⭐⭐ **stub 挡住的东西**（2026-10-25 实证，两个都是真 bug）：
#   ① 多一个 `}` ⇒ `extraneous '}' at top level` ⇒ CI 挂
#   ② `final class Gate` 写在**泛型函数**里 ⇒ `type 'Gate' cannot be nested in generic function`
#      ⇒ CI 挂（这个是 Swift 语言规则 ⇒ 沙盒 3 秒就能抓到 ⇒ 不用等 5 分钟 CI）⭐⭐⭐
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ── 找 swiftc（和 run-swift-tests.sh 用同一份逻辑 ⇒ 单一真相）──
SWIFTC=""
for c in "${SWIFT:-}/usr/bin/swiftc" /workspace/.toolchain/swift-6.3-RELEASE-ubuntu22.04/usr/bin/swiftc \
         /workspace/.toolchain/swift/usr/bin/swiftc /usr/bin/swiftc /usr/local/bin/swiftc; do
  [ -n "$c" ] && [ -x "$c" ] && { SWIFTC="$c"; break; }
done
if [ -z "$SWIFTC" ]; then
  echo "⚠️ 跳过：没找到 swiftc（Linux 编译门禁跑不了）"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ⭐ 入口文件**必须叫 main.swift**（Swift 顶层代码限制）
cp test/linux-compile-stubs.swift "$TMP/main.swift"

# ⭐⭐⭐ **要编的 App 侧文件**（纯 Foundation 的那些 + 需要 stub 的那些）
#   ⚠️ 改这个列表时 ⇒ 同步更新门禁注释 ⇒ 免得「以为编了其实没编」⭐
FILES=(
  "QiReaderLite/Core/SourceService.swift"      # ⭐⭐⭐ 本次事故的主角（引擎调用的入口）
  "QiReaderLite/Core/BookSource.swift"
  "QiReaderLite/Core/Book.swift"
  "QiReaderLite/Core/SourceVariables.swift"
  "QiReaderLite/Core/SourceDictCache.swift"
  "QiReaderLite/Core/SourceRawArchive.swift"
  "QiReaderLite/Core/LegadoCompat.swift"
)

echo "=== 编译 App 侧 Core/（swiftc 真编 ⇒ 抓语法/类型错）==="
# ⭐⭐⭐ **-swift-version 5 + minimal 并发** ⇒ 对齐 Xcode 26.2 的 Swift 5.9 默认
#   ⇒ 沙盒用的 Swift 6.3 更严 ⇒ 不对齐会**误报**（门禁比 CI 还严 ⇒ 没法用）⭐⭐⭐
if ! "$SWIFTC" -swift-version 5 -strict-concurrency=minimal -typecheck \
      "$TMP/main.swift" "${FILES[@]}" > "$TMP/err.txt" 2>&1; then
  echo "❌ App 侧 Core/ 编译失败："
  grep -E "error:" "$TMP/err.txt" | head -20 | sed 's/^/     /'
  exit 1
fi
echo "✅ 编译通过（${#FILES[@]} 个文件）"

# ⭐⭐⭐⭐⭐ **typecheck**（不只是 parse ⇒ 能抓类型错误）
#   ⚠️⚠️ **为什么必须 typecheck**：`swiftc -parse` **只查语法** ⇒ 查不出
#   `covariant 'Self' type cannot be referenced from a stored property initializer`
#   这类**类型错误** ⇒ 而它**会让 CI 挂** ⇒ 沙盒必须能抓 ⭐⭐⭐
#   （build254 CI 实证：沙盒全绿 ⇒ CI 挂 ⇒ 白等一轮）⭐⭐⭐
echo "=== typecheck（抓类型错：parse 抓不到）==="
if ! "$SWIFTC" -swift-version 5 -strict-concurrency=minimal -typecheck \
      "$TMP/main.swift" "${FILES[@]}" > "$TMP/tc.txt" 2>&1; then
  echo "❌ typecheck 失败："
  grep -E "error:" "$TMP/tc.txt" | head -20 | sed 's/^/     /'
  exit 1
fi
echo "✅ typecheck 通过"

# ⭐⭐⭐⭐⭐ **一致性比对**：stub 里的「引擎版本片段」必须与 `RuleSandbox.swift` 里的**真代码一致**
#   ⇒ 改了一边忘了另一边 ⇒ 门禁红（防止两边漂移 ⇒ 假的）⭐⭐⭐
echo "=== 引擎版本片段：stub ⇔ RuleSandbox 一致性 ==="
RS="QiReaderLite/Core/RuleSandbox.swift"
if [ -f "$RS" ]; then
  # 抽两边的关键行
  probe_rev="$(grep -oE 'static let engineRevision: String = .*' "$RS" | head -1)"
  probe_ver="$(grep -oE 'static let engineVersion = .*' "$RS" | head -1)"
  stub_rev="$(grep -oE 'static let engineRevision: String = .*' test/linux-compile-stubs.swift | head -1)"
  stub_ver="$(grep -oE 'static let engineVersion = .*' test/linux-compile-stubs.swift | head -1)"
  if [ -z "$probe_rev" ] || [ -z "$probe_ver" ]; then
    echo "  ✗ ⭐⭐⭐ RuleSandbox 里找不到 engineRevision / engineVersion 的定义（⇒ 有人改了？）"
    exit 1
  fi
  # ⭐⭐⭐ **不许用 `Self.`**（Swift 硬错误：`covariant 'Self' type cannot be referenced
  #   from a stored property initializer` ⇒ **CI 必挂** ⇒ 沙盒必须能抓）⭐⭐⭐
  #   （build254 CI 实证：就是这一行挂的 ⇒ 沙盒全绿 ⇒ 白等一轮）⭐⭐⭐
  if echo "$probe_ver" | grep -qE '\bSelf\.engineRevision\b'; then
    echo "  ✗ ⭐⭐⭐⭐⭐ RuleSandbox 的 engineVersion 用了 \`Self.engineRevision\`"
    echo "     ⇒ Swift 报 \`covariant 'Self' type cannot be referenced from a stored property initializer\`"
    echo "     ⇒ **CI 必挂** ⇒ 改成**显式类型名**（如 \`RuleSandbox.engineRevision\`）⭐⭐⭐"
    exit 1
  fi
  if echo "$stub_ver" | grep -qE '\bSelf\.engineRevision\b'; then
    echo "  ✗ ⭐⭐⭐ stub 里用了 \`Self.engineRevision\` ⇒ 同样会让 CI 挂 ⇒ 改成显式类型名"
    exit 1
  fi
  # 关键：两边的**调用形态**必须一致（类型名不同是允许的 ⇒ 只比调用结构）⭐
  norm() { echo "$1" | sed -E 's/[A-Za-z_][A-Za-z0-9_]*\.engineRevision/<TYPE>.engineRevision/g'; }
  if [ "$(norm "$probe_ver")" != "$(norm "$stub_ver")" ]; then
    echo "  ✗ ⭐⭐⭐⭐⭐ 引擎版本拼装**两边不一致**（⇒ stub 里验的就不是真代码 ⇒ 假绿）"
    echo "     RuleSandbox: $probe_ver"
    echo "     stub       : $stub_ver"
    exit 1
  fi
  echo "  ✅ 一致"
else
  echo "  （找不到 $RS ⇒ 跳过）"
fi

# ⭐⭐⭐ **泛型函数里不许嵌套类型**（Swift 硬规则 ⇒ 编译错误 ⇒ CI 挂）
#   ⇒ 单独扫一遍 ⇒ 因为它是**语言规则**，扫出来 = 100% 会挂 CI（不依赖编译器版本）⭐⭐⭐
echo "=== 泛型函数里不许嵌套类型 ==="
python3 - <<'PY'
import re, sys, pathlib
bad = 0
for p in pathlib.Path('QiReaderLite').rglob('*.swift'):
    lines = p.read_text(encoding='utf-8').split('\n')
    depth = 0
    generic_fn = None
    for i, l in enumerate(lines):
        m = re.match(r'\s*(?:(?:public|private|internal|fileprivate|open|static|final|override|mutating|nonisolated)\s+)*func\s+(\w+)\s*<', l)
        if m and depth == 0:
            generic_fn = (m.group(1), i + 1)
        # 顶层类型/协议/扩展声明
        if re.match(r'^(?:@\w+\s*)*(?:public\s+|private\s+|internal\s+|fileprivate\s+|final\s+)*(?:class|struct|enum|extension|protocol)\b', l):
            generic_fn = None
        if generic_fn:
            nm = re.match(r'\s*(?:(?:final|public|private|internal|fileprivate)\s+)*(class|struct|enum)\s+(\w+)', l)
            if nm:
                print(f"  ✗ {p}:{i+1} 泛型函数 `{generic_fn[0]}`（第 {generic_fn[1]} 行）里嵌套了类型 `{nm.group(2)}`")
                print(f"     ⇒ Swift 报错 `type '{nm.group(2)}' cannot be nested in generic function` ⇒ **CI 必挂**")
                bad += 1
        depth += l.count('{') - l.count('}')
        if depth <= 0:
            depth = 0
if bad:
    print(f"❌ 发现 {bad} 处「泛型函数里嵌套类型」⇒ 移到文件顶层")
    sys.exit(1)
print("✅ 没有")
PY
[ $? -ne 0 ] && exit 1

echo
echo "Linux 编译门禁：通过"
