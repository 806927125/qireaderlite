#!/usr/bin/env node
/**
 * **两遍跑：互斥候选只抓第一个**（2026-10-21 真机「正文是空的」根因）
 *
 * 跑法：node test/ajax-candidate-group.test.js
 *
 * ────────────────────────────────────────────────────────────
 * 背景
 *
 * 站方（🍅大灰狼聚合）的正文规则长这样：
 *
 *     try { data = java.ajax(base_url + '/content' + op); JSON.parse(data); }
 *     catch { for (i in host) {                       // ← 8 条线路
 *               data = java.ajax(host[i] + '/content' + op);
 *               JSON.parse(data);
 *               setArguments('server', host[i]); break;
 *           } }
 *
 * 这 8 条是**互斥候选**（只会用一条），不是顺序链。
 *
 * 但「两遍跑」的第 1 遍里，所有 `java.ajax` 都返回 ''（录制模式）
 * ⇒ `JSON.parse('')` 全抛 ⇒ **catch 循环把 8 条全录了下来**
 * ⇒ 宿主以前把 8 条**全抓了**。
 *
 * 💥 后果：一次正文操作向站方发了 **8 条**同 item_id 的请求
 *    ⇒ **番茄免登录访问次数上限(3 次)直接被打爆**
 *    ⇒ 缓存里躺着的全是「您今日免登录访问次数已达上限(3次)！」
 *    ⇒ 站方第 2 遍命中它 → `JSON.parse` **成功**（合法 JSON！）→ **不换线**
 *    ⇒ `content = ''` ⇒ **正文是空的** ⭐
 *
 * ────────────────────────────────────────────────────────────
 * 修法：宿主按「path + query + method 相同、只有 host 不同」归组，
 *       **每组只抓第一个**，剩下的留给站方自己换线
 *       （站方第 2 遍发现这条不行 → catch 循环录下一条 → 第 3 遍再抓）。
 *       ⇒ 一次操作最多 1~2 次请求，限流打不爆 ✅
 *       ⇒ 站方那个「线路故障，已自动切换到」机制**真正生效了**
 *          （以前是被宿主一次全抓破坏了）。
 *
 * ────────────────────────────────────────────────────────────
 * 这个门禁**不联网**（全部 mock），所以不会像活体门禁那样被站方波动带偏。
 */
const { createSandbox } = require('./harness');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

/** 造一个「catch 循环换线路」的站方脚本（3 个候选 host） */
function candidateScript(hosts) {
  return `
var hosts = ${JSON.stringify(hosts)};
var out = '';
try {
  out = java.ajax(hosts[0] + '/p');
  JSON.parse(out);
} catch (e) {
  for (var i = 1; i < hosts.length; i++) {
    try {
      out = java.ajax(hosts[i] + '/p');
      JSON.parse(out);
      break;
    } catch (e2) { /* 换下一条 */ }
  }
}
out
`;
}

(async () => {
  // ──────────────────────────────────────────────
  // ① 同组候选（path 相同、host 不同）⇒ 只抓第一个
  // ──────────────────────────────────────────────
  console.log('=== ① 同组候选只抓第一个（回归：8 条全抓会打爆番茄限流）===');
  {
    const reqs = [];
    const nativeMock = async (fn, args) => {
      if (fn === 'request') {
        reqs.push(String(args.url || ''));
        return { ok: true, code: 200, url: args.url, headers: {}, body: '{"ok":1}' };
      }
      if (fn === 'log') return { ok: true };
      return { ok: true, value: '' };
    };
    const { win } = createSandbox({ nativeMock });
    const hosts = ['https://a.example.com', 'https://b.example.com', 'https://c.example.com'];
    const r = await win.eval(
      `window.QR.rule.runJs(${JSON.stringify(candidateScript(hosts))}, {})`);

    const pReqs = reqs.filter(u => /\/p$/.test(u.split('?')[0]));
    console.log('  真实请求:', pReqs.length, pReqs.map(u => u.replace('https://', '')).join(' , '));
    console.log('  站方拿到:', JSON.stringify(String(r).slice(0, 40)));
    ok(pReqs.length === 1,
       `同组 3 个候选只该抓 1 个（实际 ${pReqs.length} 个）—— 全抓会打爆站方限流`);
    ok(pReqs[0] && pReqs[0].indexOf('a.example.com') >= 0,
       '抓的是第一个候选（base_url 那条）');
    ok(String(r).indexOf('ok') >= 0, '站方最终拿到了内容');
  }

  // ──────────────────────────────────────────────
  // ② 第一个候选失败 ⇒ 站方自己换线 ⇒ 逐条试，不是一把梭
  // ──────────────────────────────────────────────
  console.log('\n=== ② 第一个候选失败 ⇒ 站方自己换线（逐条试）===');
  {
    const reqs = [];
    const nativeMock = async (fn, args) => {
      if (fn === 'request') {
        const u = String(args.url || '');
        reqs.push(u);
        // 第一条线路 502 ⇒ 站方 JSON.parse 抛 ⇒ 应当换下一条
        if (u.indexOf('a.example.com') >= 0) {
          return { ok: true, code: 502, url: u, headers: {}, body: '<html>502</html>' };
        }
        return { ok: true, code: 200, url: u, headers: {}, body: '{"ok":2}' };
      }
      if (fn === 'log') return { ok: true };
      return { ok: true, value: '' };
    };
    const { win } = createSandbox({ nativeMock });
    const hosts = ['https://a.example.com', 'https://b.example.com', 'https://c.example.com'];
    const r = await win.eval(
      `window.QR.rule.runJs(${JSON.stringify(candidateScript(hosts))}, {})`);

    const pReqs = reqs.filter(u => /\/p$/.test(u.split('?')[0]));
    console.log('  真实请求:', pReqs.length, pReqs.map(u => u.replace('https://', '')).join(' , '));
    console.log('  站方拿到:', JSON.stringify(String(r).slice(0, 40)));
    ok(pReqs.length === 2,
       `第一条 502 时应该**逐条换**（a 失败 → b 成功 ⇒ 2 个请求），实际 ${pReqs.length} 个`);
    ok(pReqs.some(u => u.indexOf('b.example.com') >= 0),
       '换到了第二条线路 b（站方的「自动切换」机制真的生效了）');
    ok(String(r).indexOf('"ok":2') >= 0, '站方拿到了第二条线路的响应');
  }

  // ──────────────────────────────────────────────
  // ③ 不同 path 的顺序链**不受影响**（浏览器 → 交接 那条链）
  // ──────────────────────────────────────────────
  console.log('\n=== ③ 不同 path 的顺序链照旧全抓（不能被归组误伤）===');
  {
    const reqs = [];
    const nativeMock = async (fn, args) => {
      if (fn === 'request') {
        reqs.push(String(args.url || ''));
        return { ok: true, code: 200, url: args.url, headers: {}, body: '{"ok":1}' };
      }
      if (fn === 'log') return { ok: true };
      return { ok: true, value: '' };
    };
    const { win } = createSandbox({ nativeMock });
    // 两个**不同 path** 的请求（模拟「先拿 token 再交接」的顺序链）
    const code = `
var a = java.ajax('https://x.example.com/get_token');
var b = java.ajax('https://x.example.com/handover');
a + '|' + b
`;
    await win.eval(`window.QR.rule.runJs(${JSON.stringify(code)}, {})`);
    const got = reqs.map(u => u.split('/').pop());
    console.log('  真实请求:', got.join(' , '));
    ok(got.includes('get_token') && got.includes('handover'),
       '不同 path 的顺序链两个都要抓（归组不能误伤）');
  }

  // ──────────────────────────────────────────────
  // ④ 同样 path、但 **headers 不同** ⇒ 不是互斥候选，两个都要抓
  //    （番茄登录链：browser 拿 sessionid → 交接 ajax 带 sessionid，
  //      两次 ajax 的 path/query/method 完全一样，只有 cookie 不同
  //      ⇒ 早先只按 path+query+method 归组 ⇒ 第二遍被判「已试过」⇒ 永远不重抓
  //      ⇒ `sessionid=undefined` ⇒ **番茄登录直接废掉** ⭐ 由 fq-login 门禁抓出来）
  // ──────────────────────────────────────────────
  console.log('\n=== ④ 同 path 但 headers 不同 ⇒ 两个都要抓（番茄登录链）===');
  {
    const reqs = [];
    const nativeMock = async (fn, args) => {
      if (fn === 'request') {
        reqs.push({ url: String(args.url || ''), cookie: String((args.headers || {}).cookie || '') });
        return { ok: true, code: 200, url: args.url, headers: {}, body: '{"ok":1}' };
      }
      if (fn === 'log') return { ok: true };
      return { ok: true, value: '' };
    };
    const { win } = createSandbox({ nativeMock });
    // 同一个 path，但 cookie 不同（模拟「拿到 sessionid 前后各一次」）
    // ⚠️ 必须用**字符串形式** `,{json}` —— 站方（Legado）就是这么写的，
    //    而引擎的 `java.ajax(url, options)` **对象形式不认 options**（只取第一个参数）
    const code = `
var a = java.ajax('https://x.example.com/api,{"headers":{"cookie":"sessionid=undefined"}}');
var b = java.ajax('https://x.example.com/api,{"headers":{"cookie":"sessionid=REAL"}}');
a + '|' + b
`;
    await win.eval(`window.QR.rule.runJs(${JSON.stringify(code)}, {})`);
    console.log('  真实请求:', reqs.length, reqs.map(r => r.cookie).join(' , '));
    ok(reqs.length === 2,
       `同 path、cookie 不同的两次请求都要抓（实际 ${reqs.length} 次）—— 否则番茄登录拿到 undefined`);
    ok(reqs.some(r => r.cookie.indexOf('REAL') >= 0),
       '带真 sessionid 的那次也抓了（登录链的交接请求）');
  }

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
