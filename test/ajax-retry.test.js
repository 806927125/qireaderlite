#!/usr/bin/env node
/**
 * **ajax 失败必须能重试** —— 别把空串当成功缓存起来
 *
 * 起因（真机 2026-10-21，「详情页时好时坏」）：
 *   站方 `java.ajax(url)` 是**同步**的（`JSON.parse(java.ajax(url))` 到处在用），
 *   轻阅的原生桥是异步的 ⇒ 只能「两遍跑」：
 *     第 1 遍只录 URL（返回空串）→ 引擎把 URL 抓回来填进缓存
 *     第 2 遍命中缓存 → 同步返回真正的正文
 *
 * ⚠️⚠️ **原来的 bug**：
 *   `fetchRecorded` 里 **ajax 失败时也往缓存里写空串**：
 *       .catch(function (e) { out[u] = ''; ... })
 *       .then(function (resp) { out[u] = (resp && resp._body) || ''; ... })
 *   ⇒ 网络抖一下（超时 / 502）⇒ 缓存里躺了个空串
 *   ⇒ 第 2 遍 `java.ajax` **命中了这个空串** ⇒ 返回 ''
 *   ⇒ 而且因为「命中缓存就不录了」⇒ `recorded.length === 0`
 *   ⇒ 判定成「这一遍是真的」⇒ **直接返回空串，不重试**
 *   ⇒ 站方 `JSON.parse('')` 炸 ⇒ 详情页加载失败
 *
 *   ⇒ **一次网络抖动 = 整条详情规则死定** ⭐ 这就是「时好时坏」
 *
 *   修法：**失败/空响应不写缓存** ⇒ 下一遍会重新录、重新请求
 *        ⇒ 两遍跑天然带上了重试能力（MAX_PASS 5 轮兜底）。
 *
 * 这个门禁直接验「第一次失败、第二次成功 ⇒ 最终必须拿到真内容」。
 */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./harness');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

(async () => {
  // ── ① 第一次 request 失败、第二次成功 ────────────────────────────
  console.log('=== ① ajax 第一次超时、第二次成功 ===');
  let n = 0;
  const nativeMock = async (fn, args) => {
    if (fn === 'request') {
      n++;
      if (n === 1) return { ok: false, error: '请求超时' };
      return { ok: true, code: 200, body: '{"title":"真结果"}', url: args.url };
    }
    return { ok: true, value: '' };
  };
  const { win } = createSandbox({ nativeMock });
  let got = null;
  try {
    got = await win.QR.rule.runJs('java.ajax("https://x.com/")', {});
  } catch (e) {
    got = 'THREW: ' + (e && e.message);
  }
  ok(n >= 2, `失败后必须重试（request 至少调 2 次，实调 ${n} 次）`);
  ok(got === '{"title":"真结果"}',
     '重试成功后必须拿到真内容（实际: ' + JSON.stringify(String(got)).slice(0, 80) + '）');

  // ── ② 失败不能把空串写进缓存 ────────────────────────────────────
  console.log('\n=== ② 失败不污染缓存 ===');
  const ra = fs.readFileSync(
    path.join(__dirname, '..', 'QiReaderLite', 'Resources', 'engine', 'rule-analyzer.js'), 'utf8');
  const fetchBlock = (ra.match(/function fetchRecorded[\s\S]*?\n {2}\}/) || [''])[0];
  ok(fetchBlock.length > 0, '找到 fetchRecorded');
  // ⚠️ 必须**剥掉注释**再断言 —— 注释里写着「原来是 out[u] = ''」，
  //    那是在讲历史，不是现在的代码。
  const codeOnly = fetchBlock
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/(^|[^:])\/\/.*$/gm, '$1');
  // ⚠️⚠️ 2026-10-21 更新：**允许**在「同组还有备选线路」时写空串 ——
  //   那是为了让站方的 catch 循环能换线（见 ajax-candidate-group.test.js）。
  //   但**单候选**时写空串 = 一次抖动就死定 ⇒ 必须禁止。
  //   ⇒ 断言收紧成：写空串必须**受条件约束**（同组有备选才写）。
  const hasBlankWrite = /out\[u\]\s*=\s*''/.test(codeOnly);
  const hasGuard = /g\.total\s*>\s*1/.test(codeOnly);
  ok(!hasBlankWrite || hasGuard,
     `写空串必须受「同组还有备选线路」约束（单候选失败要能重试）`
     + `（有写空串=${hasBlankWrite} 有条件=${hasGuard}）`);
  ok(/delete out\[u\]/.test(codeOnly),
     '失败时用 delete out[u] 把这条缓存清掉（让下一遍能重试）');

  // ── ③ 源码里要有「重试」这个动作，不能只是删缓存 ────────────────
  console.log('\n=== ③ 源码自证 ===');
  ok(/delete out\[u\]/.test(ra), 'rule-analyzer.js 里有 delete out[u]');
  ok(/MAX_PASS/.test(ra), '还有 MAX_PASS 轮数上限兜底');

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
