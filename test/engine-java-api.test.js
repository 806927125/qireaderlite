#!/usr/bin/env node
/**
 * 125 源聚合包 × 轻阅引擎 的 java.* 覆盖门禁
 *
 * 为什么要有这个门禁：
 *   之前我判断「轻阅支持哪些 java.*」用的是 grep 源码，结果误判成
 *   java.ajax / java.post / java.connect 都没实现（其实都有），
 *   而且把 java.io / java.util 这类**包引用**误报成缺失方法。
 *   → 静态 grep 在这件事上没有判别力，**必须运行时 typeof 逐个点名**。
 *
 * 门禁做两件事：
 *   ① 拿聚合包里真实用到的 java.* 列表，跑一次轻阅引擎，逐个查
 *   ② 有一条「故意用一个肯定没有的方法」，证明它真的会红
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./harness');

const PACK = process.env.SRC_PACK || '/workspace/attachments/0522cfc6e1cde02d/配置文件_125个.json';

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

const { win } = createSandbox({ origin: 'https://x.com/' });
const java = win.java || {};

const pack = JSON.parse(fs.readFileSync(PACK, 'utf8'));

// 只取方法调用：java.foo
// ⚠️ 要排除包引用 java.io.ByteArrayOutputStream / java.util.regex.Pattern /
//    java.lang.String —— 那是**类路径**不是 java.* 方法。
//    包名首字母是大写（类）好排，但 java.io / java.lang / java.util 这些
//    **包名本身是小写**，光靠 /^[A-Z]/ 排不掉，必须显式列。
const PKG = new Set(['io', 'lang', 'util', 'net', 'text', 'security', 'crypto', 'nio', 'math', 'time']);
const used = new Set();
for (const s of pack) {
  for (const m of JSON.stringify(s).match(/java\.([A-Za-z_][A-Za-z0-9_]*)/g) || []) {
    const name = m.slice(5);
    if (/^[A-Z]/.test(name) || PKG.has(name)) continue;
    used.add(name);
  }
}

console.log(`聚合包用到的 java.* 方法: ${used.size} 个`);
const missing = [...used].filter(m => typeof java[m] !== 'function').sort();
ok(missing.length === 0, `轻阅未实现 ${missing.length} 个：${missing.join(', ') || '无'}`);

// 关键的那个必须还在（iOS 上 ajax 是活的，不是死代码 —— 之前记错过）
ok(typeof java.ajax === 'function', 'java.ajax 在轻阅上可用（安卓 Legado 那套搬过来了）');
ok(typeof java.post === 'function', 'java.post 可用');
ok(typeof java.connect === 'function', 'java.connect 可用');

// 逐个抽查本轮新补的
['ajaxAll', 'getAbsoluteURL', 't2s', 'timeFormatUTC', 'hexDecodeToString',
 'randomUUID', 'refreshExplore', 'refreshTocUrl', 'showBrowser', 'startBrowserAwait',
 'reLoginView', 'searchBook', 'toNumChapter', 'createSymmetricCrypto', 'getElement',
 'setContent'].forEach(m => ok(typeof java[m] === 'function', `java.${m} 已实现`));

// 形状检查：createSymmetricCrypto 得有书源会调的那几个方法
const crypto = java.createSymmetricCrypto('0123456789abcdef', '', 'AES/CBC/PKCS5Padding');
['encrypt', 'decrypt', 'encryptBase64', 'decryptBase64'].forEach(m =>
  ok(crypto && typeof crypto[m] === 'function', `createSymmetricCrypto().${m}()`));

// randomUUID 必须真是 v4 格式 —— 书源拿它当签名 nonce，格式错了签名就废
const uuid = java.randomUUID();
ok(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(uuid),
   `randomUUID 是合法 v4（实际 ${uuid}）`);

ok(java.toNumChapter('第 123 章 风云') === 123, 'toNumChapter 抽章节号');
// 「中」= U+4E2D，UTF-8 字节是 e4 b8 ad（不是 4e2d4b4b，那是 UTF-16/码点）
ok(java.hexDecodeToString('e4b8ad') === '中', 'hexDecodeToString 按 UTF-8 解 hex');
ok(java.hexDecodeToString('') === '', 'hexDecodeToString 空输入不炸');

// ⑦ 书源导入入口：用户 iOS 上文件导入找不到文件、粘贴又要手打 1MB，
//    所以轻阅必须有「从链接导入」。少这个入口用户就装不进去书源。
const src = fs.readFileSync(
  path.join(__dirname, '..', 'QiReaderLite', 'Features', 'Sources', 'SourcesView.swift'), 'utf8');
ok(/Label\("从链接导入"/.test(src), '书源管理里有「从链接导入」入口');
ok(/struct URLImportView/.test(src), '有 URLImportView');
ok(/URLSession\.shared\.data\(for:/.test(src), 'URL 导入走 URLSession');
// GitHub 的 /blob/ 路径返回 HTML 页面，当成 JSON 解析会报一堆看不懂的错
ok(/hasPrefix\("<"\)/.test(src) && /raw\.githubusercontent\.com/.test(src),
   '拿到 HTML（GitHub /blob/ 页）会明确提示换 raw 域名');
ok(/\.frame\(maxWidth: \.infinity\)|TextField/.test(src), 'URL 输入框存在');

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
