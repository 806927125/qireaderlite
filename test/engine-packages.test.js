// packages_stub.js 在**真实引擎环境**里的集成验证
// 跑法：node test/engine-packages.test.js
//
// 为什么要有这个文件：
//   test/packages-native.test.js 是纯 Node，java.* 用的是桩。
//   而 packages-native.js 里 `java.digestHex` 要用 `java.md5Encode` / `java.sha1Encode`
//   —— 这两个方法**只有 java-api.js 装了才有**。
//   所以必须用 harness.js（jsdom + 完整脚本链，跟真机注入顺序一致）验证一次，
//   否则可能出现"桩测试全绿、真机 MessageDigest 拿到空串"的情况。
const { createSandbox } = require('./harness');
const crypto = require('crypto');

let failed = 0, passed = 0;
function check(name, cond, extra) {
  if (cond) { passed++; console.log('  ✓', name); }
  else { failed++; console.log('  ✗', name, extra === undefined ? '' : ('→ ' + extra)); }
}

const { win } = createSandbox();
const P = win.Packages;

console.log('=== 1. 命名空间就位 ===');
check('Packages 存在', !!P);
check('java.lang.Integer 存在', !!(P.java && P.java.lang && P.java.lang.Integer));
check('java.util.Base64 存在', !!(P.java && P.java.util && P.java.util.Base64));
check('javax.crypto.Cipher 存在', !!(P.javax && P.javax.crypto && P.javax.crypto.Cipher));
check('java.security.MessageDigest 存在', !!(P.java && P.java.security && P.java.security.MessageDigest));
check('com.jayway.jsonpath.JsonPath 存在', !!(P.com && P.com.jayway && P.com.jayway.jsonpath));
check('io.legado.app.help 存在', !!(P.io && P.io.legado && P.io.legado.app));
check('cn.hutool.core.util.StrUtil 存在', !!(P.cn && P.cn.hutool && P.cn.hutool.core));

console.log('\n=== 2. java.digestHex 真的接到了 java-api.js ===');
check('全局 java 对象存在', typeof win.java === 'object' && win.java !== null);
check('java.md5Encode 存在（来自 java-api.js）', typeof win.java.md5Encode === 'function');
check('java.sha1Encode 存在（来自 java-api.js）', typeof win.java.sha1Encode === 'function');
check('java.digestHex 存在（来自 packages-native.js）', typeof win.java.digestHex === 'function');

console.log('\n=== 3. MessageDigest 端到端（跟 Node crypto 对比）===');
(function () {
  const vectors = [
    ['MD5', 'md5'], ['SHA-1', 'sha1'], ['SHA-256', 'sha256'],
  ];
  // ⚠️ 必须用 win.String —— jsdom 的 String 原型跟 Node 的不是同一个，
  //    packages_stub 装的是 jsdom window 的 String.prototype.getBytes。
  const S = win.String;
  const samples = ['', 'abc', 'hello 轻阅', 'a'.repeat(200)];
  let ok = true, bad = '';
  for (const [javaName, nodeName] of vectors) {
    for (const s of samples) {
      let hex;
      try {
        const md = P.java.security.MessageDigest.getInstance(javaName);
        const bytes = md.digest(new S(s).getBytes('UTF-8'));
        hex = Array.from(bytes).map(b => (b & 0xff).toString(16).padStart(2, '0')).join('');
      } catch (e) { ok = false; bad = `${javaName} 抛错: ${e.message}`; break; }
      const node = crypto.createHash(nodeName).update(s, 'utf8').digest('hex');
      if (hex !== node) { ok = false; bad = `${javaName}("${s.slice(0, 12)}") → ${hex} != ${node}`; break; }
    }
    if (!ok) break;
  }
  check('MessageDigest MD5/SHA-1/SHA-256 与 Node 一致', ok, bad);
})();

console.log('\n=== 4. Cipher 端到端（书源最常用的 AES/CBC）===');
(function () {
  try {
    const key = '1234567890123456', iv = 'abcdefghijklmnop';
    const S = win.String;
    const c = P.javax.crypto.Cipher.getInstance('AES/CBC/PKCS5Padding');
    c.init(1, new P.javax.crypto.spec.SecretKeySpec(new S(key).getBytes('UTF-8'), 'AES'),
                new P.javax.crypto.spec.IvParameterSpec(new S(iv).getBytes('UTF-8')));
    const encB64 = String(c.doFinal(new S('轻阅 test').getBytes('UTF-8')));
    const dec = crypto.createDecipheriv('aes-128-cbc', Buffer.from(key, 'utf8'), Buffer.from(iv, 'utf8'));
    const plain = Buffer.concat([dec.update(Buffer.from(encB64, 'base64')), dec.final()]);
    check('AES/CBC 加密结果可被 Node 解回原文', plain.toString('utf8') === '轻阅 test', plain.toString('utf8'));
  } catch (e) {
    check('AES/CBC 加密结果可被 Node 解回原文', false, e.message);
  }
})();

console.log('\n=== 5. String.getBytes / 字节往返 ===');
(function () {
  const S = win.String;
  const s = '轻阅 bytes';
  const bytes = new S(s).getBytes('UTF-8');
  const back = win._nativeBytesToStr(Array.from(bytes), 'UTF-8');
  check('getBytes → bytesToStr 往返一致', back === s, `${back} != ${s}`);
})();

console.log('\n=== 6. 引擎没被破坏（老 API 仍可用）===');
(function () {
  check('QR 命名空间还在', !!win.QR);
  check('QR.java.base64Decode 还在', !!(win.QR && win.QR.java && typeof win.QR.java.base64Decode === 'function'));
  // md5Encode / sha1Encode 挂在 java 对象上（QR.java === java），QR 上没有
  check('QR.java.md5Encode 还在', !!(win.QR && win.QR.java && typeof win.QR.java.md5Encode === 'function'));
  check('QR.java.sha1Encode 还在', !!(win.QR && win.QR.java && typeof win.QR.java.sha1Encode === 'function'));
  check('java.base64Decode 还在', typeof win.java.base64Decode === 'function');
})();

console.log('\n' + '═'.repeat(52));
console.log(`  通过 ${passed}  失败 ${failed}`);
console.log('═'.repeat(52));
process.exit(failed === 0 ? 0 : 1);
