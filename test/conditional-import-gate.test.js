#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：条件编译块里的符号，文件必须 import 对应的框架**
 *
 * ⚠️⚠️⚠️ **为什么必须有它**（2026-11-21 移植柴阅的真实事故）：
 *   柴阅的 `Digests` 被我从 `Crypto/Crypto.swift` 拆到独立文件（为了 Linux 能编）⭐⭐⭐
 *   ⇒ 拆的时候**没把 `import CommonCrypto` 一起带走** ⭐⭐⭐
 *   ⇒ **Linux 沙盒完全编不到那段**（`#if canImport(CommonCrypto)` 为假）⭐⭐⭐
 *   ⇒ **沙盒门禁全绿** ⇒ 直到 CI（Xcode 26）才报：
 *      `Digests.swift:46:56: error: cannot find 'CC_SHA224_DIGEST_LENGTH' in scope` ⭐⭐⭐
 *   ⇒ ⚠️ **这正是记忆里的老坑：「沙盒编不到 = 没有门禁」** ⭐⭐⭐
 *   ⇒ 正解：**静态扫**（哪个文件用了某个框架的条件块 ⇒ 该文件必须 import 它）⭐⭐⭐
 *
 * ⭐⭐⭐ **本门禁是跨平台的静态检查**（不编译）⇒ **Apple-only 的错误也能在沙盒抓到** ⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const ENGINE_DIR = path.join(ROOT, 'LegadoEngine/Sources');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓', m); }
  else { fail++; console.log('  ✗', m, extra === undefined ? '' : '→ ' + extra); }
};

/** 递归找所有 .swift */
function walk(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else if (e.name.endsWith('.swift')) out.push(p);
  }
  return out;
}

/** 去掉注释（注释里写 `import CommonCrypto` 会造成假绿） */
function stripComments(t) {
  return t.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/\/\/[^\n]*/g, ' ');
}

const files = walk(ENGINE_DIR);

/**
 * ⭐⭐⭐ **probe 必须避开「字符串字面量」**（2026-11-21 实证）：
 *   柴阅的代码里到处是 `transformation: "AES"` ⇒ 用 `\bAES\b` 当 probe ⇒ **满屏误报** ⭐⭐⭐
 *   ⇒ 正解：只匹配**类型/函数位置**的写法（`Insecure.MD5` / `HMAC<` / `SymmetricKey(`）⭐⭐⭐
 *
 * ⚠️⚠️ **FoundationNetworking 不设规则**（Apple 上 Foundation 自带 URLSession ⇒ 不需要它）
 *   ⇒ 只在 Linux 才需要 ⇒ 而 **Linux 门禁会真编** ⇒ 真有问题会自己暴露 ⭐⭐⭐
 */
const FRAMEWORKS = [
  { name: 'CommonCrypto', probe: /\bCC_[A-Za-z0-9_]+/ },
  { name: 'CryptoKit', probe: /\bInsecure\.(?:MD5|SHA1)\b|\bHMAC<|\bSymmetricKey\(|\bSHA(?:256|384|512)\.hash\b/ },
  { name: 'JavaScriptCore', probe: /\bJSContext\b|\bJSValue\b|\bJSExport\b|\bJSVirtualMachine\b/ },
  { name: 'CoreFoundation', probe: /\bCFGetTypeID\b|\bCFBooleanGetTypeID\b|\bCFNumberIsFloatType\b|\bCFStringConvert[A-Za-z]*\b/ },
];

console.log('=== 1. 每个文件：用了某框架的条件块 ⇒ 必须 import 它 ===');
{
  let checked = 0;
  for (const f of files) {
    const raw = fs.readFileSync(f, 'utf8');
    const code = stripComments(raw);
    const rel = path.relative(ROOT, f);
    for (const fw of FRAMEWORKS) {
      // 该文件是否**用到了**这个框架的符号？
      if (!fw.probe.test(code)) continue;
      // 是否 import 了（无论是否在条件块里）
      const imported = new RegExp(`^\\s*import\\s+${fw.name}\\b`, 'm').test(code);
      // 或通过 `import Crypto`（swift-crypto 再导出 CryptoKit）间接拿到
      const indirect = fw.name === 'CryptoKit' && /^\s*import\s+Crypto\b/m.test(code);
      ok(imported || indirect,
         `${rel}：用到 ${fw.name} 的符号 ⇒ 必须 import ${fw.name}`,
         imported || indirect ? '' : '缺 import ⇒ Apple 平台会报「cannot find ... in scope」');
      checked++;
    }
  }
  ok(checked > 0, `扫了 ${files.length} 个 swift 文件，命中 ${checked} 处框架依赖`);
}

console.log('\n=== 2. 条件编译块必须闭合 ===');
{
  for (const f of files) {
    const code = stripComments(fs.readFileSync(f, 'utf8'));
    const opens = (code.match(/^\s*#if\b/gm) || []).length;
    const closes = (code.match(/^\s*#endif\b/gm) || []).length;
    const rel = path.relative(ROOT, f);
    ok(opens === closes, `${rel}：#if 与 #endif 配平（${opens}/${closes}）`,
       opens === closes ? '' : '不配平 ⇒ 编译报错');
  }
}

console.log('\n=== 3. 变异对照（改坏 ⇒ 必须红） ===');
{
  // 模拟：把 `Digests.swift` 的 `import CommonCrypto` 删掉 ⇒ 必须被门禁抓住
  const target = path.join(ENGINE_DIR, 'ChaiyueEngine/Crypto/Digests.swift');
  const orig = fs.readFileSync(target, 'utf8');
  const mutated = orig.replace(/import CommonCrypto/, '// import CommonCrypto');
  ok(mutated !== orig, '变异锚点命中（import CommonCrypto）');
  if (mutated !== orig) {
    const code = stripComments(mutated);
    const hasImport = /^\s*import\s+CommonCrypto\b/m.test(code);
    const usesCC = /\bCC_[A-Za-z0-9_]+/.test(code);
    ok(!(hasImport) && usesCC, '★ 变异后：用了 CC_ 符号却没有 import ⇒ 门禁能抓住（★ 有牙齿）');
  }
  // 模拟：#if 不闭合
  const bad = orig.replace(/#endif/g, '');
  const code2 = stripComments(bad);
  const o = (code2.match(/^\s*#if\b/gm) || []).length;
  const c = (code2.match(/^\s*#endif\b/gm) || []).length;
  ok(o !== c, '★ 变异后：#if/#endif 不配平 ⇒ 门禁能抓住（★ 有牙齿）');
}

console.log(`\n通过 ${pass} / 失败 ${fail}`);
process.exit(fail === 0 ? 0 : 1);
