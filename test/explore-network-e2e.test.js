#!/usr/bin/env node
'use strict';
/* ============================================================================
 * ⭐⭐⭐⭐⭐ **发现页真网络 e2e**（站方 exploreUrl + 真实网络 ⇒ 必须出真分类）
 *
 * ── 为什么要有这条 ────────────────────────────────────────────────────
 *   真机症状（2026-11-10）：发现页只有 **1 个分类** ⇒ App 判「结果不可信」
 *   ⇒ 站方聚合源在「分类接口没通」时会**造一个兜底分类**（🦄UAA 分类加载失败 /
 *     🐹次元姬 未登录 / …）⇒ **分类数极少 = 站方接口没通** ⭐⭐⭐
 *
 *   ⇒ 这条门禁在沙盒里用**真网络**跑站方的 exploreUrl：
 *     · 分类数 ≫ 3      ⇒ 站方接口通（真机若只有 1 个 ⇒ 设备侧网络/超时问题）
 *     · 分类数 ＝ 1/0   ⇒ 站方接口已挂（**站方自己的问题**，不是 App 的）
 *
 * ⚠️ **无外网时优雅跳过**（CI 常常没网 ⇒ 不能假红）⇒ 但会**显式说明跳过了**
 *
 * ⚠️ **为什么用老引擎的 harness 而不是新引擎**：
 *   站方 exploreUrl 的 JS 需要**带方法的 `source`**（`source.get/put`）
 *   ⇒ 新引擎的 Node 后端给的是拍平对象 ⇒ 跑不出真分类（沙盒限制）
 *   ⇒ 老引擎 harness 的 `source` 语义完整 ⇒ 能忠实复刻站方行为 ⭐⭐⭐
 * ========================================================================== */

const fs = require('fs');
const path = require('path');
const https = require('https');
const http = require('http');

const ROOT = path.resolve(__dirname, '..');
const SRC = process.env.NOVELHUB_SRC || '/workspace/out/NovelHub聚合小说-轻阅版.json';

let pass = 0, fail = 0;
function ok(c, msg, extra) {
  if (c) { pass++; console.log('  ✓ ' + msg); }
  else { fail++; console.log('  ✗ ' + msg + (extra ? '  → ' + extra : '')); }
}

function fetchRaw(url, headers) {
  return new Promise((res) => {
    let u;
    try { u = new URL(url); } catch (e) { return res({ code: 0, headers: {}, body: '', error: 'bad url' }); }
    const mod = u.protocol === 'https:' ? https : http;
    const r = mod.request({
      hostname: u.hostname, port: u.port || (u.protocol === 'https:' ? 443 : 80),
      path: u.pathname + u.search, method: 'GET', headers: headers || {},
    }, (rs) => {
      let b = '';
      rs.setEncoding('utf8');
      rs.on('data', (c) => { b += c; });
      rs.on('end', () => res({ code: rs.statusCode, headers: rs.headers, body: b }));
    });
    r.on('error', (e) => res({ code: 0, headers: {}, body: '', error: String(e) }));
    r.setTimeout(25000, () => { r.destroy(); res({ code: 0, headers: {}, body: '', error: 'timeout' }); });
    r.end();
  });
}

(async () => {
  if (!fs.existsSync(SRC)) {
    console.log('⚠️  没有源文件：' + SRC + ' ⇒ 跳过（不假红）');
    console.log('\n✅ 通过 0 / 失败 0（跳过）');
    process.exit(0);
  }
  const { createSandbox } = require('./harness');
  const doc = JSON.parse(fs.readFileSync(SRC, 'utf8'));
  const src = Array.isArray(doc) ? doc[0] : doc;

  const reqs = [];
  async function nativeMock(fn, args) {
    switch (fn) {
      case 'request': {
        const url = String(args.url || '');
        const hs = args.headers || {};
        reqs.push({ url, headers: hs });
        const r = await fetchRaw(url, hs);
        const last = reqs[reqs.length - 1];
        last.code = r.code; last.len = r.body.length; last.err = r.error || '';
        return { ok: r.code > 0 && r.code < 500, code: r.code, url,
                 headers: r.headers, _body: r.body, body: r.body };
      }
      case 'toast': case 'log': return { ok: true };
      case 'deviceID': case 'androidId': return { ok: true, value: 'dev-id' };
      case 'getString': return { ok: true, value: '' };
      case 'getStringArray': return { ok: true, value: [] };
      default: return { ok: true, value: '' };
    }
  }

  const { win } = createSandbox({ nativeMock });
  const crypto = require('crypto');
  const H = crypto.createHash('md5').update('pw', 'utf8').digest('hex');
  const payload = {
    source: Object.assign({}, src, {
      __variables: JSON.stringify({ nhAuthed: H, nhPwdHash: H }),
      __variable: '', __loginInfo: {},
    }),
    cookieSnapshot: {},
  };

  const r = await win.eval(`window.__qrInvoke('exploreKinds', ${JSON.stringify(payload)})`);
  const kinds = (r && r.kinds) || [];
  console.log('=== 站方 exploreUrl（真网络）===');
  console.log('  分类数 = ' + kinds.length);
  console.log('  前 5 个 = ' + kinds.slice(0, 5).map((k) => k.title).join(' | '));
  console.log('  真实请求数 = ' + reqs.length);

  if (!reqs.length) {
    console.log('⚠️  一个请求都没发 ⇒ **沙盒没外网** ⇒ 跳过（不假红）');
    console.log('\n✅ 通过 0 / 失败 0（跳过）');
    process.exit(0);
  }

  ok(reqs.length >= 1, '⭐⭐⭐ 站方的分类接口确实被调了（' + reqs.length + ' 次）');
  ok(kinds.length > 3,
     '⭐⭐⭐⭐⭐ 分类数正常（>3）⇒ 站方接口通 ⇒ **真机只有 1 个就说明设备侧网络/超时有问题**',
     '实际 ' + kinds.length);
  // ⚠️⚠️ **站方本来就会带几条「未登录/加载失败」条目**（次元姬这类未登录的平台）
  //   ⇒ 断言只能是「它们只能是少数」⇒ **不能断言一个都没有**（会误报）⭐⭐⭐
  const fb = kinds.filter((k) => /分类加载失败|未登录/.test(String(k.title || '')));
  console.log('  其中「未登录/加载失败」类 = ' + fb.length + ' 条：'
              + fb.slice(0, 3).map((k) => k.title).join(' | '));
  ok(fb.length <= Math.max(2, Math.floor(kinds.length / 10)),
     '⭐⭐⭐ 兜底类条目只是少数（多数 ⇒ 主流水线的分类接口正常）',
     '兜底 ' + fb.length + ' / 总 ' + kinds.length);
  for (const q of reqs.slice(0, 3)) {
    console.log(`     [${q.code}] ${String(q.url).slice(0, 110)}`);
  }
  console.log('\n' + (fail === 0 ? '✅' : '❌') + ` 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail === 0 ? 0 : 1);
})().catch((e) => { console.error('炸了：', e); process.exit(2); });
