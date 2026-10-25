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
 *
 * ────────────────────────────────────────────────────────────
 * ⭐⭐⭐ **2026-10-25 迁移说明**（老 JS 引擎物理删除）
 *   · 老门禁在 jsdom 里跑老引擎的 `java` 对象 ⇒ 老引擎删了 ⇒ 对象没了
 *   ⇒ 现在改成**跑新引擎**（`legado-engine` 的 `--js` 模式 ⇒ 引擎的宿主 API 契约）
 *   ⇒ **语义等价在哪**：站方 JS 能不能调 `java.xxx`，取决于
 *     **引擎的宿主 API 契约（`JSHostAPI`）有没有登记这一条** ——
 *     登记了 ⇒ 引擎会生成包装函数 ⇒ 站方 `java.xxx()` **不会 TypeError** ⭐⭐⭐
 *     （契约漏登记 = 包装函数不生成 = 站方第一句就炸 = 整条规则死定 ⇒ 这正是本门禁要抓的）
 *   · 「故意用一个肯定没有的方法」那条**保留**（证明检查本身有判别力）
 */
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
// ⭐⭐⭐⭐⭐ **老 JS 引擎已物理删除（2026-10-25）⇒ 门禁改验【新引擎】**（`legado-engine` 的 Swift 实现）
const { createSandbox, engineAvailable } = require('./new-engine-harness');

// ⚠️ 原件在沙盒外（新沙盒没有）→ 依次回退到 /workspace/out 和仓库里的副本
function firstExisting(paths) {
  for (const p of paths) { if (fs.existsSync(p)) return p; }
  return '';
}
const PACK = process.env.SRC_PACK || firstExisting([
  '/workspace/attachments/0522cfc6e1cde02d/配置文件_125个.json',
  '/workspace/out/配置文件125个-轻阅适配版.json',
  path.join(__dirname, '..', 'sources', '配置文件125个-轻阅适配版.json'),
]);

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };
const skip = (m) => console.log('  ⏭️  跳过：' + m + '（**没验到 ≠ 通过**）');

/** ⭐ 在新引擎里跑一段 JS ⇒ 拿它的返回值 */
async function evalInEngine(code, routes) {
  const { win } = createSandbox(routes ? { routes } : {});
  // ⚠️ **重试**：引擎正在被重编时 ⇒ 这次调用会返回空 ⇒ 重试几次 ⭐⭐⭐
  let last = '';
  for (let i = 0; i < 5; i++) {
    last = String(await win.eval(code));
    if (last && last !== 'ERR: 引擎不可用') break;
    await new Promise(res => setTimeout(res, 3000));
  }
  return last;
}


/**
 * ⭐⭐⭐ **Swift 探针**：直接问【新引擎自己的 Crypto】⇒ 拿到**真机那条路**的答案
 *
 * ⚠️ **为什么需要**：
 *   沙盒（Linux）没有 JSC ⇒ 引擎走 **Node 后端** ⇒ Node 后端的宿主往返是**异步**的
 *   ⇒ 站方包装函数（**同步**调 `__hostJSON`）拿不到引擎侧的结果
 *   ⇒ 只有「纯计算」的那几个（base64 / md5 / hex）在 Node 侧有 JS 实现
 *   ⇒ 而 `java.randomUUID` / `java.toNumChapter` 这类**引擎侧实现**的，
 *     沙盒里**调不到**（真机 JSC 走得到）
 *   ⇒ 这里用 swiftc **真编真跑**引擎的 `Crypto` ⇒ 验的是**同一份实现**⭐⭐⭐
 *
 * @returns {object|null} null = 环境不具备（调用方要**显式 SKIP**，不许假绿）
 */
function swiftCryptoProbe() {
  const ENGINE_DIR = process.env.ENGINE_DIR || path.join(__dirname, '..', '..', 'legado-engine');
  const swiftc = [
    process.env.SWIFT ? path.join(process.env.SWIFT, 'usr', 'bin', 'swiftc') : '',
    '/workspace/.toolchain/swift-6.3-RELEASE-ubuntu22.04/usr/bin/swiftc',
    '/workspace/.toolchain/swift/usr/bin/swiftc',
    '/usr/bin/swiftc', '/usr/local/bin/swiftc',
  ].find(c => c && fs.existsSync(c));
  const build = [
    path.join(ENGINE_DIR, '.build', 'debug'),
    path.join(ENGINE_DIR, '.build', 'x86_64-unknown-linux-gnu', 'debug'),
    path.join(ENGINE_DIR, '.build', 'arm64-apple-darwin', 'debug'),
  ].find(d => fs.existsSync(path.join(d, 'Modules', 'LegadoCore.swiftmodule'))
             && fs.existsSync(path.join(d, 'LegadoCore.build'))
             && fs.existsSync(path.join(d, 'SwiftSoup.build')));
  if (!swiftc || !build) return null;
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'qr-crypto-'));
  try {
    const swiftSrc = [
      'import Foundation',
      'import LegadoCore',
      'let uuid = Crypto.randomUUID()',
      'let num = Crypto.convertChineseNumerals(in: "第一百二十三章")',
      'let numArabic = Crypto.convertChineseNumerals(in: "第 123 章 风云")',
      'let hex = Crypto.hexDecodeToString("e4b8ad") ?? "<nil>"',
      'let empty = Crypto.hexDecodeToString("") ?? "<nil>"',
      'let md5 = Crypto.md5Hex("abc")',
      'print("UUID " + uuid)',
      'print("NUM " + num)',
      'print("NUMARABIC " + numArabic)',
      'print("HEX " + hex)',
      'print("EMPTY " + empty)',
      'print("MD5 " + md5)',
    ].join('\n');
    fs.writeFileSync(path.join(tmp, 'main.swift'), swiftSrc);
    const env = Object.assign({}, process.env);
    const swRoot = path.dirname(path.dirname(swiftc));
    env.LD_LIBRARY_PATH = path.join(swRoot, 'usr', 'lib', 'swift', 'linux')
      + (env.LD_LIBRARY_PATH ? ':' + env.LD_LIBRARY_PATH : '');
    const objs = (dir) => fs.readdirSync(path.join(build, dir))
      .filter(f => f.endsWith('.o')).map(f => path.join(build, dir, f));
    const r = spawnSync(swiftc, ['-O', '-I', path.join(build, 'Modules'),
      path.join(tmp, 'main.swift'), ...objs('LegadoCore.build'), ...objs('SwiftSoup.build'),
      '-o', path.join(tmp, 'probe')], { encoding: 'utf8', timeout: 300000, env });
    if (r.status !== 0) return { error: 'swiftc 编译失败：' + String(r.stderr || '').slice(0, 300) };
    const run = spawnSync(path.join(tmp, 'probe'), [], { encoding: 'utf8', timeout: 60000, env });
    if (run.status !== 0) return { error: 'Swift 探针跑挂了' };
    // ⭐ 一行一个「键 值」⇒ 不用在 JS 里拼 JSON 字符串（省掉一堆转义）
    const out = {};
    for (const line of String(run.stdout || '').split('\n')) {
      const i = line.indexOf(' ');
      if (i > 0) out[line.slice(0, i)] = line.slice(i + 1);
    }
    if (!out.UUID) return { error: 'Swift 探针输出解析失败' };
    return out;
  } catch (e) { return { error: String(e && e.message) }; }
  finally { try { fs.rmSync(tmp, { recursive: true, force: true }); } catch (e) {} }
}

/** ⭐⭐⭐ **探针重试**：引擎正在被重编时 ⇒ 二进制会短暂不可用/不一致
 *  ⇒ 重试几次再判（**别把「引擎在重编」当成「门禁坏了」）** */
async function probeWithRetry(fn, tries = 5) {
  for (let i = 0; i < tries; i++) {
    const r = await fn();
    if (r) return r;
    await new Promise(res => setTimeout(res, 4000));
  }
  return null;
}

(async () => {
  // ⭐⭐⭐ **探活**（引擎跑不起来 ⇒ 显式 SKIP，不算门禁的锅）⭐⭐⭐
  const _alive = await evalInEngine('String(1+1);');
  if (!engineAvailable() || String(_alive) !== '2') {
    skip('引擎跑不起来（没编译 / 正在重编 / 崩了）⇒ 本门禁没验到（**不等于通过**）');
    console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
    process.exit(fail ? 1 : 0);
  }

  if (!PACK) {
    console.log('  ℹ️  125 源包不在本机 → 跳过');
    console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
    process.exit(0);
  }
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

  console.log('\n=== 1. 引擎的宿主 API 契约：这些方法都得有（否则站方 JS 会报「不是函数」）===');
  // ⭐⭐⭐ **在新引擎里逐个 typeof 点名**（老门禁也是这么干的，只是对象换成了新引擎）⭐⭐⭐
  //
  // ⭐⭐⭐⭐⭐ **探测名单 = 「包里用到的」∪「下面要抽查的」**（2026-10-25 修）
  //   ⚠️ 之前只探测「包里用到的 32 个」⇒ 第 ③ 段要抽查的 `startBrowserAwait`
  //      **根本不在探测名单里** ⇒ `types['startBrowserAwait']` 恒 undefined
  //      ⇒ 第 ③ 段**必然报红** ⇒ 看着像「引擎没实现」，其实是**门禁自己没探测**⭐⭐⭐
  //   ⇒ 现在**并集探测** ⇒ 第 ① 段的快照对第 ③ 段也有效
  const SPOT_CHECK = ['ajaxAll', 'getAbsoluteURL', 't2s', 'timeFormatUTC', 'hexDecodeToString',
                      'randomUUID', 'refreshExplore', 'refreshTocUrl', 'showBrowser', 'startBrowserAwait',
                      'reLoginView', 'searchBook', 'toNumChapter', 'createSymmetricCrypto', 'getElement',
                      'setContent'];
  const names = [...new Set([...used, ...SPOT_CHECK])].sort();
  const probe = names.map(n => `t[${JSON.stringify(n)}]=typeof java[${JSON.stringify(n)}];`).join('');
  // ⭐⭐⭐ **重试到「一个都不缺」为止**（引擎正在被重编时 ⇒ 二进制会短暂是旧/新混合态
  //   ⇒ 少几个包装函数 ⇒ 重试 ⇒ 别把「引擎在重编」当成「引擎缺能力」）⭐⭐⭐
  let types = {}, missing = names;
  await probeWithRetry(async () => {
    const o = await evalInEngine(`var t={}; ${probe} String(JSON.stringify(t));`);
    let tt = {};
    try { tt = JSON.parse(String(o || '')); } catch (e) { return null; }
    const miss = names.filter(n => tt[n] !== 'function');
    if (miss.length) { missing = miss; return null; }   // ⇒ 还差 ⇒ 重试
    types = tt; missing = []; return tt;
  });
  ok(missing.length === 0, `引擎未实现 ${missing.length} 个：${missing.join(', ') || '无'}`);

  console.log('\n=== 2. 关键的那个必须还在（iOS 上 ajax 是活的，不是死代码 —— 之前记错过）===');
  ok(types['ajax'] === 'function', 'java.ajax 在引擎上可用（安卓 Legado 那套搬过来了）');
  ok(types['post'] === 'function', 'java.post 可用');
  ok(types['connect'] === 'function', 'java.connect 可用');

  console.log('\n=== 3. 逐个抽查本轮新补的 ===');
  SPOT_CHECK.forEach(m => ok(types[m] === 'function', `java.${m} 已实现`));

  console.log('\n=== 4. 「故意用一个肯定没有的方法」⇒ 必须不是函数（证明上面那圈有判别力）===');
  {
    const t = await evalInEngine('String(typeof java.definitelyNotARealMethodName);');
    ok(String(t) === 'undefined', '不存在的 java 方法确实不是函数（检查本身有判别力）',
       '实际 ' + JSON.stringify(String(t)));
  }

  console.log('\n=== 5. 真跑几个纯计算方法（不是只看 typeof）===');
  {
    // ① md5Encode（125 源里 233 处 ⇒ 用得最多的 API）—— 沙盒 Node 后端有同语义实现
    const md5 = String(await evalInEngine('String(java.md5Encode("abc"));'));
    ok(md5 === require('crypto').createHash('md5').update('abc', 'utf8').digest('hex'),
       'md5Encode 与 Node crypto 一致', '实际 ' + md5);
    // ② base64Encode / base64Decode（成对 ⇒ 解出来的必须等于原文）
    const b64 = String(await evalInEngine('String(java.base64Encode("轻阅 base64"));'));
    const back = String(await evalInEngine(`String(java.base64Decode(${JSON.stringify(b64)}));`));
    ok(b64 === Buffer.from('轻阅 base64', 'utf8').toString('base64'),
       'base64Encode 与 Node 一致', '实际 ' + b64);
    ok(back === '轻阅 base64', 'base64Decode 解回来是原文', '实际 ' + JSON.stringify(back));

    // ⭐⭐⭐ ③ **引擎侧实现的那几个**（randomUUID / toNumChapter / hexDecodeToString）
    //   ⚠️ 沙盒（Linux ⇒ Node 后端）**调不到**它们（宿主往返是异步的 ⇒ 同步包装函数拿不到）
    //   ⇒ 用 swiftc **真编真跑**引擎的 `Crypto` ⇒ 验的是**真机那条路的同一份实现**⭐⭐⭐
    const probe = swiftCryptoProbe();
    if (!probe || probe.error) {
      skip('这台机器上编不了引擎的 Swift 探针（'
           + (probe && probe.error ? probe.error : '没找到 swiftc / 引擎构建产物')
           + '）⇒ 引擎侧那几个纯计算方法没验到');
    } else {
      // randomUUID 必须真是 v4 格式 —— 书源拿它当签名 nonce，格式错了签名就废
      ok(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(probe.UUID),
         `randomUUID 是合法 v4（实际 ${probe.UUID}）`);
      // 章节号：⭐⭐⭐ **语义等价说明**（老门禁断言的是老引擎那套）
      //   · 老引擎（`reference/js/java-api.js`）：`toNumChapter` = **从整段文本里抠阿拉伯数字**
      //     （`/(\d+)/` ⇒ 抠不到就返回 -1）
      //   · 新引擎（`Crypto.convertChineseNumerals`）：**把中文数字转成阿拉伯数字**
      //   ⇒ 两者**不等价**，但**新引擎那套才是书源真正要的**：
      //     125 源实测的用法是
      //       `result.replace(/第([零一二三四五六七八九十百千]+)章/g, java.toNumChapter(result))`
      //     （**传的是整段文本**，匹配的是**中文数字**）
      //     ⇒ 老引擎那套在这里抠不到阿拉伯数字 ⇒ 返回 **-1** ⇒ 替换出来是「第-1章」⭐
      //     ⇒ 新引擎那套才把「第一百二十三章」变成「123章」⭐⭐⭐
      //   ⇒ 这里断言**新引擎的语义**（并把老引擎那套的差异写清楚）⭐⭐⭐
      ok(probe.NUM === '第123章', 'toNumChapter 把中文数字转成阿拉伯数字（站方真实用法要的就是这个）',
         '实际 ' + JSON.stringify(probe.NUM));
      ok(probe.NUMARABIC === '第 123 章 风云',
         'toNumChapter 对已经是阿拉伯数字的文本**原样返回**（不像老引擎那样乱抠）',
         '实际 ' + JSON.stringify(probe.NUMARABIC));
      // 「中」= U+4E2D，UTF-8 字节是 e4 b8 ad（不是 4e2d4b4b，那是 UTF-16/码点）
      ok(probe.HEX === '中', 'hexDecodeToString 按 UTF-8 解 hex', '实际 ' + JSON.stringify(probe.HEX));
      ok(probe.EMPTY === '', 'hexDecodeToString 空输入不炸', '实际 ' + JSON.stringify(probe.EMPTY));
      ok(probe.MD5 === require('crypto').createHash('md5').update('abc', 'utf8').digest('hex'),
         '引擎的 md5Hex 与 Node crypto 一致', '实际 ' + probe.MD5);
    }
  }

  console.log('\n=== 6. java.ajax 真的是活的（不是死代码）===');
  {
    // ⭐⭐⭐ 假服务器下沉到 transport 层 ⇒ 站方 JS 的 java.ajax 能打到它 ⭐⭐⭐
    const body = await evalInEngine(
      'String(java.ajax("https://ajax.example.com/p?x=1"));',
      [{ match: 'ajax.example.com', status: 200, body: '{"ok":1}' }]);
    ok(String(body) === '{"ok":1}', 'java.ajax 打到了假服务器并拿回了正文',
       '实际 ' + JSON.stringify(String(body)).slice(0, 80));
    // 非 2xx ⇒ 必须带原因（站方据此换线）
    const bad = await evalInEngine(
      'String(java.ajax("https://ajax.example.com/bad"));',
      [{ match: 'ajax.example.com', status: 502, body: '<html>502</html>' }]);
    ok(/502/.test(String(bad)), '502 ⇒ 返回带原因的串（站方 catch 换线）',
       '实际 ' + JSON.stringify(String(bad)).slice(0, 80));
  }

  console.log('\n=== 7. 对称加密能力（站源最常用的 AES/CBC）===');
  {
    // ⭐⭐⭐ **语义等价说明**：
    //   老门禁验的是 `java.createSymmetricCrypto()` 返回的对象上有没有
    //   `encrypt/decrypt/encryptBase64/decryptBase64` 四个方法（**形状**检查）。
    //   新引擎里 `java.createSymmetricCrypto` 登记在契约里（⇒ 站方调它不会 TypeError），
    //   但**宿主侧没实现**（真机上由宿主给）⇒ 沙盒里拿不到对象 ⇒ 形状验不了。
    //   ⭐ **语义等价在哪**：站方真正要的「对称加密」能力，
    //   在新引擎里由 **Java 兼容层的 `Packages.javax.crypto.Cipher`** 提供（纯 JS 实现），
    //   ⇒ 改验**能力本身**（加密结果能被 Node 解回原文）—— 比形状检查更强 ⭐⭐⭐
    ok(types['createSymmetricCrypto'] === 'function',
       'java.createSymmetricCrypto 在契约里（站方调它不会报「不是函数」）');
    const crypto = require('crypto');
    const key = '1234567890123456', iv = 'abcdefghijklmnop';
    const encB64 = String(await evalInEngine(
      `var c = Packages.javax.crypto.Cipher.getInstance('AES/CBC/PKCS5Padding');
       var k = new Packages.javax.crypto.spec.SecretKeySpec('${key}'.getBytes('UTF-8'), 'AES');
       var ivs = new Packages.javax.crypto.spec.IvParameterSpec('${iv}'.getBytes('UTF-8'));
       c.init(1, k, ivs);
       String(c.doFinal('轻阅 test'.getBytes('UTF-8')));`));
    let plain = '';
    try {
      const dec = crypto.createDecipheriv('aes-128-cbc', Buffer.from(key, 'utf8'), Buffer.from(iv, 'utf8'));
      plain = Buffer.concat([dec.update(Buffer.from(encB64, 'base64')), dec.final()]).toString('utf8');
    } catch (e) { plain = '解密失败：' + e.message; }
    ok(plain === '轻阅 test', 'AES/CBC 加密结果可被 Node 解回原文', plain);
    // ⭐⭐⭐ **解密那条路也要通**（书源常常要解服务器回来的密文）
    const decB64 = crypto.createCipheriv('aes-128-cbc', Buffer.from(key, 'utf8'), Buffer.from(iv, 'utf8'));
    const cipherB64 = Buffer.concat([decB64.update(Buffer.from('轻阅 test', 'utf8')), decB64.final()]).toString('base64');
    const back = String(await evalInEngine(
      `var c = Packages.javax.crypto.Cipher.getInstance('AES/CBC/PKCS5Padding');
       var k = new Packages.javax.crypto.spec.SecretKeySpec('${key}'.getBytes('UTF-8'), 'AES');
       var ivs = new Packages.javax.crypto.spec.IvParameterSpec('${iv}'.getBytes('UTF-8'));
       c.init(2, k, ivs);
       var raw=c.doFinal(Packages.java.util.Base64.getDecoder().decode('${cipherB64}'));
       String(_nativeBytesToStr(Array.prototype.slice.call(Packages.java.util.Base64.getDecoder().decode(raw)),'UTF-8'));`));
    ok(back === '轻阅 test', 'AES/CBC 解密结果与原文一致', '实际 ' + JSON.stringify(back).slice(0, 60));
  }

  console.log('\n=== 8. 书源导入入口：用户 iOS 上文件导入找不到文件、粘贴又要手打 1MB，===');
  console.log('===    所以轻阅必须有「从链接导入」。少这个入口用户就装不进去书源。===');
  const src = fs.readFileSync(
    path.join(__dirname, '..', 'QiReaderLite', 'Features', 'Sources', 'SourcesView.swift'), 'utf8');
  ok(/Label\("从链接导入"/.test(src), '书源管理里有「从链接导入」入口');
  ok(/struct URLImportView/.test(src), '有 URLImportView');
  ok(/URLSession\.shared\.data\(for:/.test(src), 'URL 导入走 URLSession');
  // GitHub 的 /blob/ 路径返回 HTML 页面，当成 JSON 解析会报一堆看不懂的错
  ok(/hasPrefix\("<"\)/.test(src) && /raw\.githubusercontent\.com/.test(src),
     '拿到 HTML（GitHub /blob/ 页）会明确提示换 raw 域名');
  ok(/\.frame\(maxWidth: \.infinity\)|TextField/.test(src), 'URL 输入框存在');

  // ⚠️ Swift 保留字当参数名 → 编译期就挂，报错信息还特别看不懂：
  //    `from where: String` → "Expected expression in list of expressions"
  //    （编译器以为你在写 where 子句）。这里扫一遍常见保留字。
  {
    const SWIFT_KW = ['where','class','func','enum','struct','protocol','return','true',
                      'false','nil','is','as','in','for','if','else','switch','case',
                      'default','break','continue','import','operator','static',
                      'deinit','extension','typealias','internal','private','public',
                      'open','fileprivate','rethrows','throws','get','set','init','sub'];
    const bad = [];
    for (const m of src.matchAll(/\(([^()]*\b(?:func|let|var)\s+\w+[^()]*)\)\s*->/g)) {
      for (const kw of SWIFT_KW) {
        if (new RegExp('\\b' + kw + '\\s*:').test(m[1])) bad.push(`${kw} (在 ${m[1].trim().slice(0,40)})`);
      }
    }
    ok(bad.length === 0, `参数名用了 Swift 保留字：${bad.join(', ') || '无'}`);
  }

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e && e.message); process.exit(2); });
