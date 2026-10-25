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
# ⚠️⚠️ **沙盒会把 /tmp 清掉**（2026-10-21 踩过：/tmp/swift 没了 →
#    Swift 层门禁**静默跳过** → 「全绿」其实是没跑 ⇒ 一行 Swift 代码都没被验过）。
# ⇒ 所以：**先找 /tmp，再找 workspace 里的常驻位置**，还不行就自动建软链。
for c in /tmp/swift/usr/bin/swiftc \
         "$(dirname "$(dirname "$0")")/../.toolchain/swift/usr/bin/swiftc" \
         "$(command -v swiftc || true)"; do
  [ -x "$c" ] && { SWIFTC="$c"; break; }
done
# 找到 workspace 里的但 /tmp/swift 不存在 ⇒ 建软链，让下面那段 LD_LIBRARY_PATH 生效
if [ -n "$SWIFTC" ] && [ ! -x /tmp/swift/usr/bin/swiftc ]; then
  WLIB="$(cd "$(dirname "$(dirname "$SWIFTC")")" && pwd)"
  if [ -d "$WLIB" ]; then
    mkdir -p /tmp 2>/dev/null
    ln -sfn "$WLIB" /tmp/swift 2>/dev/null || true
  fi
fi
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

# 门禁 ⑤ 要读仓库里的源码（断言原生请求层真的调了 AnalyzeUrl）
export QR_REPO_DIR="$(pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ⚠️ swiftc 编译多个文件时，入口文件必须叫 main.swift（顶层代码限制）
cp test/host-tools-test.swift "$TMP/main.swift"

echo "=== 编译 Core/HostTools.swift（swiftc 真编）==="
if ! "$SWIFTC" -O "$TMP/main.swift" QiReaderLite/Core/HostTools.swift -o "$TMP/compat-test" 2>"$TMP/err.txt"; then
  echo "❌ 编译失败："
  cat "$TMP/err.txt" | head -30
  exit 1
fi
echo "✓ 编译通过"

echo
"$TMP/compat-test" | tee "$TMP/out1.txt"
rc=${PIPESTATUS[0]}
SP=0; SF=0
_sum() {  # $1=输出文件 → 把「通过 N / 失败 M」加进 SP/SF
  local n m
  n=$(grep -oE '通过 [0-9]+' "$1" | tail -1 | grep -oE '[0-9]+' || echo 0)
  m=$(grep -oE '失败 [0-9]+' "$1" | tail -1 | grep -oE '[0-9]+' || echo 0)
  SP=$((SP + ${n:-0})); SF=$((SF + ${m:-0}))
}
_sum "$TMP/out1.txt"

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
"$TMP/url-test" | tee "$TMP/out2.txt"
rc2=${PIPESTATUS[0]}
[ $rc2 -ne 0 ] && rc=$rc2
_sum "$TMP/out2.txt"

# ── 第三组：书籍 URL 规范化（Core/Book.swift）───────────────
# ⚠️ data:/blob:/ 自定义 scheme **必须原样返回** ——
#    `URL(string:).absoluteString` 会把 `,{"type":"x"}` 百分号编码 →
#    引擎的 `,{` 后缀剥离失效 → 聚合源详情页整条规则静默失效（真机专属的坑）。
echo
echo "=== 编译 Core/Book.swift（swiftc 真编）==="
mkdir -p "$TMP/book"
cp test/book-url-test.swift "$TMP/book/main.swift"
if ! "$SWIFTC" -O "$TMP/book/main.swift" QiReaderLite/Core/Book.swift -o "$TMP/book-test" 2>"$TMP/err3.txt"; then
  echo "❌ 编译失败："
  cat "$TMP/err3.txt" | head -30
  exit 1
fi
echo "✓ 编译通过"
echo
"$TMP/book-test" | tee "$TMP/out3.txt"
rc3=${PIPESTATUS[0]}
[ $rc3 -ne 0 ] && rc=$rc3
_sum "$TMP/out3.txt"

# ── 第四组：书源变量合并（Core/SourceVariables.swift）────────
# ⭐ 站方的 `getArguments` 只在变量串为空时才给默认表 ⇒ 只写一项就把
#    server/tab/sources/proxy 全丢掉 ⇒ 真机「目录 0 章」的根因之一。
echo
echo "=== 编译 Core/SourceVariables.swift（swiftc 真编）==="
mkdir -p "$TMP/vars"
cp test/vars-merge-test.swift "$TMP/vars/main.swift"
if ! "$SWIFTC" -O "$TMP/vars/main.swift" QiReaderLite/Core/SourceVariables.swift -o "$TMP/vars-test" 2>"$TMP/err4.txt"; then
  echo "❌ 编译失败："
  cat "$TMP/err4.txt" | head -30
  exit 1
fi
echo "✓ 编译通过"
echo
"$TMP/vars-test" | tee "$TMP/out4.txt"
rc4=${PIPESTATUS[0]}
[ $rc4 -ne 0 ] && rc=$rc4
_sum "$TMP/out4.txt"

# ── 第四组之二：**书源导入补齐**（Core/BookSource.swift）────────
# ⭐⭐⭐ 2026-10-24 真机：「登录界面整没了」的根因就在这个文件里
#   `BookSource.init(from:)` 是**白名单解码** ⇒ 模型后加的字段（`loginUi` 是 build153 才加的）
#   ⇒ **老版本存下来的源，存储里根本没这个键** ⇒ 登录面板永远说「loginUi 是空的」
#   ⇒ 站方 19 个登录按钮 + 邮箱/密码输入框**一起消失**
# ⇒ 修法：导入时用**原始 JSON**（权威）把模型缺的字段补上
# ⇒ 这组门禁钉死它：把实现改坏 ⇒ 必须红
echo
echo "=== 编译 Core/BookSource.swift（swiftc 真编）==="
mkdir -p "$TMP/import"
cp test/source-import-patch-test.swift "$TMP/import/main.swift"
if ! "$SWIFTC" -O "$TMP/import/main.swift" QiReaderLite/Core/BookSource.swift QiReaderLite/Core/SourceRawArchive.swift -o "$TMP/import-test" 2>"$TMP/err4b.txt"; then
  echo "❌ 编译失败："
  cat "$TMP/err4b.txt" | head -30
  exit 1
fi
echo "✓ 编译通过"
echo
"$TMP/import-test" | tee "$TMP/out4b.txt"
rc4b=${PIPESTATUS[0]}
[ $rc4b -ne 0 ] && rc=$rc4b
_sum "$TMP/out4b.txt"

# ── 第四组之三：**源字典缓存**（Core/SourceDictCache.swift）────
# ⭐⭐⭐ 2026-10-24 真机「app 死机」的真凶（崩溃日志 0x8BADF00D 实证）：
#   每个 op 都把整个源（大灰狼 158KB）编码 + Foundation 解析一遍
#   ⇒ 每次 op 几 MB 的分配 ⇒ **主线程在 malloc 锁上被拖死** ⇒ iOS watchdog 杀进程
# ⇒ 这组门禁钉死「同一个源只编码一次」
echo
echo "=== 编译 Core/SourceDictCache.swift（swiftc 真编）==="
mkdir -p "$TMP/dictcache"
cp test/source-dict-cache-test.swift "$TMP/dictcache/main.swift"
if ! "$SWIFTC" -O "$TMP/dictcache/main.swift" QiReaderLite/Core/BookSource.swift QiReaderLite/Core/SourceRawArchive.swift QiReaderLite/Core/SourceDictCache.swift -o "$TMP/dictcache-test" 2>"$TMP/err4c.txt"; then
  echo "❌ 编译失败："
  cat "$TMP/err4c.txt" | head -30
  exit 1
fi
echo "✓ 编译通过"
echo
"$TMP/dictcache-test" | tee "$TMP/out4c.txt"
rc4c=${PIPESTATUS[0]}
[ $rc4c -ne 0 ] && rc=$rc4c
_sum "$TMP/out4c.txt"

# ── 第四组之四：简介的 HTML 清洗（2026-10-25 真机：`<p></p>` 露在详情页上）──
# ⭐⭐⭐ 纯 Foundation ⇒ 沙盒能真编真跑 ⇒ 3 秒反馈
echo
echo "=== 编译 Core/IntroHTMLCleaner.swift（swiftc 真编）==="
mkdir -p "$TMP/intro"
cp test/intro-html-cleaner-test.swift "$TMP/intro/main.swift"
if ! "$SWIFTC" -O "$TMP/intro/main.swift" QiReaderLite/Core/IntroHTMLCleaner.swift -o "$TMP/intro-test" 2>"$TMP/err4d.txt"; then
  echo "❌ 编译失败："
  cat "$TMP/err4d.txt" | head -30
  exit 1
fi
echo "✓ 编译通过"
echo
"$TMP/intro-test" | tee "$TMP/out4d.txt"
rc4d=${PIPESTATUS[0]}
[ $rc4d -ne 0 ] && rc=$rc4d
_sum "$TMP/out4d.txt"

# ── 第五组：新引擎适配层（老 JS 引擎 → 自研 Swift 引擎）────
# ⭐⭐⭐ 这组的意义：适配层把两个模型的字段名一一对上
#   ⇒ 对错一个字段 = 「某条规则静默失效」⇒ iOS 真机构建要等 CI ⇒ 这里 3 秒抓错
# ⚠️ 需要本地已编译的 legado-engine（LegadoCore 模块）⇒ 没有就**跳过**（别假绿）
LEGADO_MODULES="${LEGADO_MODULES:-../legado-engine/.build/debug/Modules}"
if [ -f "$LEGADO_MODULES/LegadoCore.swiftmodule" ]; then
  echo
  echo "=== 编译新引擎适配层（swiftc 真编）==="
  mkdir -p "$TMP/engine"
  cp test/engine-backend-test.swift "$TMP/engine/main.swift"
  # ⚠️ 链接要带上 **LegadoCore / SwiftSoup 的目标文件**
  #   （SwiftPM 的 library product 默认是**静态**的 ⇒ 没有 .a/.so 可链 ⇒ 只能链 .o）
  LEGADO_BUILD="${LEGADO_BUILD:-../legado-engine/.build/debug}"
  if ! "$SWIFTC" -O -I "$LEGADO_MODULES" \
        "$TMP/engine/main.swift" \
        test/linux-shims/EngineBackendStubs.swift \
        QiReaderLite/Core/BookSource.swift \
        QiReaderLite/Core/SourceRawArchive.swift \
        QiReaderLite/Core/HostTools.swift \
        QiReaderLite/Core/SourceVariables.swift \
        QiReaderLite/Core/EngineBackend.swift \
        QiReaderLite/Core/ServiceError.swift \
        QiReaderLite/Core/LegadoEngineBackend.swift \
        "$LEGADO_BUILD"/LegadoCore.build/*.o \
        "$LEGADO_BUILD"/SwiftSoup.build/*.o \
        -o "$TMP/engine-test" 2>"$TMP/err5.txt"; then
    echo "❌ 编译失败："
    cat "$TMP/err5.txt" | head -30
    exit 1
  fi
  echo "✓ 编译通过"
  echo
  "$TMP/engine-test" | tee "$TMP/out5.txt"
  rc5=${PIPESTATUS[0]}
  [ $rc5 -ne 0 ] && rc=$rc5
  _sum "$TMP/out5.txt"
else
  echo
  echo "⚠️  没找到 LegadoCore 模块（$LEGADO_MODULES）⇒ 跳过新引擎适配层的门禁"
fi

# ⚠️ 汇总行必须**只有一行**、且是**合并后的总数** ——
#    跑器的汇总解析取「最后一行」⇒ 三组各打一行会把总数算错。
echo
echo "✅ 通过 $SP / 失败 $SF（swift 原生层合并）"
exit $rc
