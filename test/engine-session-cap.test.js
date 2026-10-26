/**
 * **引擎会话封顶门禁**（2026-10-26 jetsam 6.8GB 实证）
 *
 * 背景（真机崩溃日志 + 用户线索「老引擎一点问题没有」）：
 *   ① jetsam：`QingYue` **单进程** 425984 页 ×16KB = **6.8GB** ⇒ 被系统内存杀
 *      ⇒ 现象 =「闪退」+ **没有 .ips** ⭐⭐⭐
 *   ② **老引擎（WKWebView）的 JS 跑在独立 WebContent 进程** ⇒ 站方脚本再野
 *      **也不算 App 的内存** ⇒ 所以老引擎一点问题没有 ⭐⭐⭐
 *   ③ **新引擎（Swift/JSC）的 JS 跑在 App 进程内** ⇒ 全算 App 的 ⇒ jetsam 杀 App ⭐⭐⭐
 *   ④ App 侧：**一个源 = 一个会话 = 一个 JSC context**（引擎侧 contextLock 复用）
 *      ⇒ 而会话**只增不减**（只有超时/手动重置才清）⇒ **内存随「用过的源数」线性涨** ⭐⭐⭐
 *   ⑤ 搜索**默认扫所有启用的源**（用户有 125 个）⇒ 一次搜索就建几十个 context ⇒ 峰值爆表 ⭐⭐⭐
 *
 * ⭐⭐⭐ 本门禁钉三件事（「钉已修好」）：
 *   ① **会话数有上限**（LRU ⇒ 超了就淘汰最久未用的 ⇒ JSC context 释放）
 *   ② **全源搜索的并发有上限**（滑动窗口 ⇒ 不是 125 个并发 op）
 *   ③ **面板看得见**（会话数 + 上限）⇒ 真机一眼看出「有没有在涨」
 *
 * ⚠️ LRU 的**逻辑**单独放 `Core/LRUKeys.swift`（纯 Foundation）⇒ 这里能**真跑**验
 *   ⇒ 不是「只 grep 到符号就算过」的假绿 ⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.join(__dirname, '..');
const APP = path.join(ROOT, 'QiReaderLite');

let pass = 0, fail = 0;
function ok(c, label, extra) {
  if (c) { pass++; console.log(`  ✓ ${label}`); }
  else { fail++; console.log(`  ✗ ${label}${extra ? '  → ' + extra : ''}`); }
}

/** ⭐ 剥注释（注释掉的代码不算数 ⇒ 否则门禁假绿） */
function stripComments(src) {
  let out = '', i = 0;
  const n = src.length;
  let inLine = false, inBlock = false, inStr = null;
  while (i < n) {
    const c = src[i], c2 = src.substr(i, 2);
    if (inLine) { if (c === '\n') { inLine = false; out += c; } i++; continue; }
    if (inBlock) { if (c2 === '*/') { inBlock = false; i += 2; continue; } if (c === '\n') out += c; i++; continue; }
    if (inStr) {
      out += c;
      if (c === '\\') { out += src[i + 1] || ''; i += 2; continue; }
      if (c === inStr) inStr = null;
      i++; continue;
    }
    if (c2 === '//') { inLine = true; i += 2; continue; }
    if (c2 === '/*') { inBlock = true; i += 2; continue; }
    if (c === '"' || c === "'") { inStr = c; out += c; i++; continue; }
    out += c; i++;
  }
  return out;
}

function findSwiftc() {
  const cands = [
    process.env.SWIFTC,
    `${process.env.SWIFT || ''}/usr/bin/swiftc`,
    '/workspace/.toolchain/swift/usr/bin/swiftc',
    '/workspace/.toolchain/swift-6.3-RELEASE-ubuntu22.04/usr/bin/swiftc',
    '/opt/swift/swift-6.1.2-RELEASE-debian12/usr/bin/swiftc',
    '/usr/bin/swiftc',
    '/usr/local/bin/swiftc',
  ].filter(Boolean);
  for (const c of cands) {
    try { fs.accessSync(c, fs.constants.X_OK); return c; } catch (e) { /* 下一个 */ }
  }
  return null;
}

const lruPath = path.join(APP, 'Core/LRUKeys.swift');
const backendPath = path.join(APP, 'Core/LegadoEngineBackend.swift');
const searchPath = path.join(APP, 'Features/Search/SearchView.swift');
const sbPath = path.join(APP, 'Core/RuleSandbox.swift');

console.log('\n── 1. 会话封顶（一个源一个 JSC context ⇒ 不封顶就只增不减）──');
ok(fs.existsSync(lruPath), 'Core/LRUKeys.swift 存在（LRU 逻辑单独成件 ⇒ 沙盒能真测）');
const lru = fs.existsSync(lruPath) ? stripComments(fs.readFileSync(lruPath, 'utf8')) : '';
ok(/class LRUKeys/.test(lru), '有 LRUKeys 类型');
ok(/func insert\(/.test(lru), '有 insert（超限返回被淘汰的）');
ok(/func touch\(/.test(lru), '有 touch（命中提到最近使用）');

const be = fs.existsSync(backendPath) ? stripComments(fs.readFileSync(backendPath, 'utf8')) : '';
ok(/maxLiveSessions\s*=\s*\d+/.test(be), '有会话数上限常量');
const cap = Number((be.match(/maxLiveSessions\s*=\s*(\d+)/) || [])[1] || 0);
ok(cap > 0 && cap <= 8, `上限是个小数字（当前 ${cap} ⇒ 不会随源数涨）`);
ok(/LRUKeys\(limit:/.test(be), '适配层用 LRUKeys 管顺序（不是裸数组）');
ok(/sessionOrder\.insert\(/.test(be), '新建会话时会走封顶逻辑');
ok(/removeValue\(forKey: evictedKey\)/.test(be), '被淘汰的会话真的被移除（⇒ JSC context 释放）');
ok(/var liveSessionCount/.test(be), '有「活着的会话数」可观测');

console.log('\n── 2. 全源搜索不能 125 个并发（峰值会爆）──');
const sv = fs.existsSync(searchPath) ? stripComments(fs.readFileSync(searchPath, 'utf8')) : '';
ok(/maxConcurrentSearches\s*=\s*\d+/.test(sv), '有搜索并发上限常量');
const conc = Number((sv.match(/maxConcurrentSearches\s*=\s*(\d+)/) || [])[1] || 0);
ok(conc > 0 && conc <= 8, `并发上限是个小数字（当前 ${conc}）`);
ok(/while next < limit/.test(sv), '是滑动窗口（先塞满、每完成一个补一个）');
ok(!/for s in targets\s*\{\s*\n\s*group\.addTask/.test(sv),
   '**不能**是「所有源一次性 addTask」（那才是爆内存的写法）');

console.log('\n── 3. 面板要看得见（会话数 + 内存水位）──');
const sb = fs.existsSync(sbPath) ? stripComments(fs.readFileSync(sbPath, 'utf8')) : '';
ok(/liveSessionCount/.test(sb), '面板显示活着的会话数');
ok(/maxLiveSessions/.test(sb), '面板显示会话上限');
ok(/MemoryMeter\.panelLine/.test(sb), '面板有内存水位那一行');

console.log('\n── 4. 真跑一遍 LRU 逻辑（需要 swiftc）──');
const swiftc = findSwiftc();
if (!swiftc) {
  console.log('  ⏭ 跳过：没找到 swiftc ⇒ **这段没验到**（不算通过）');
} else {
  const tmp = fs.mkdtempSync('/tmp/lru-');
  const mainSwift = path.join(tmp, 'main.swift');
  fs.writeFileSync(mainSwift, `
import Foundation

func expect(_ cond: Bool, _ label: String) {
  if cond { print("  ✓ " + label) } else { print("  ✗ " + label); exit(1) }
}

// ① 限额之内 ⇒ 不淘汰
let a = LRUKeys(limit: 3)
expect(a.insert("s1") == nil, "第 1 个不淘汰")
expect(a.insert("s2") == nil, "第 2 个不淘汰")
expect(a.insert("s3") == nil, "第 3 个不淘汰")
expect(a.count == 3, "顺序表有 3 个")
// ② 超限 ⇒ 淘汰**最久未用的**
expect(a.insert("s4") == "s1", "第 4 个淘汰最久未用的 s1")
expect(a.count == 3, "淘汰后数量还是 ≤ 限额")
expect(a.oldest == "s2", "最旧的是 s2")
// ③ 命中 ⇒ 提到最近使用 ⇒ 下次淘汰的是另一个
a.touch("s2")
expect(a.oldest == "s3", "touch 之后 s2 不再是最旧")
expect(a.insert("s5") == "s3", "淘汰的是 s3（不是刚 touch 过的 s2）")
// ④ 移除 / 清空
a.remove("s4")
expect(a.count == 2, "remove 生效")
a.removeAll()
expect(a.count == 0, "removeAll 生效")
// ⑤ limit 至少为 1（防呆）
expect(LRUKeys(limit: 0).limit == 1, "limit=0 会被兜成 1")
print("SWIFT_OK")
`);
  try {
    const bin = path.join(tmp, 'lru');
    execFileSync(swiftc, ['-swift-version', '5', '-o', bin, lruPath, mainSwift],
                 { stdio: 'pipe', encoding: 'utf8' });
    const out = execFileSync(bin, [], { stdio: 'pipe', encoding: 'utf8' });
    out.split('\n').filter(l => l.includes('✓')).forEach(l => { pass++; console.log(l); });
    ok(out.includes('SWIFT_OK'), 'swift 断言全过');
  } catch (e) {
    fail++;
    console.log('  ✗ swift 跑挂了 ⇒ ' + String(e.message).split('\n').slice(0, 4).join(' | '));
    if (e.stdout) console.log('    stdout: ' + String(e.stdout).slice(0, 400));
  } finally {
    try { fs.rmSync(tmp, { recursive: true, force: true }); } catch (e) { /* 忽略 */ }
  }
}

console.log(`\n通过 ${pass} / 失败 ${fail}`);
if (fail > 0) process.exit(1);
