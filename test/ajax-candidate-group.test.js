#!/usr/bin/env node
/**
 * **互斥候选：只试到成功那一条**（老宿主「两遍跑只抓同组第一条」的等价语义）
 *
 * 跑法：node test/ajax-candidate-group.test.js
 *
 * ────────────────────────────────────────────────────────────
 * 背景（老宿主的老语义）
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
 * 老宿主（老 JS 引擎）是**两遍跑**：
 *   第 1 遍只录 URL（返回空串）⇒ `JSON.parse('')` 全抛 ⇒ catch 循环把 8 条全录了下来
 *   ⇒ 老宿主按「path + query + method 相同、只有 host 不同」**归组** ⇒ **每组只抓第一个**
 *   ⇒ 剩下的留给站方自己换线 ⇒ 一次操作最多 1~2 次请求 ⇒ 限流打不爆 ✅
 *
 * 💥 反面：一次正文操作向站方发了 **8 条**同 item_id 的请求
 *    ⇒ **番茄免登录访问次数上限(3 次)直接被打爆**
 *    ⇒ 缓存里躺着的全是「您今日免登录访问次数已达上限(3次)！」
 *    ⇒ 站方第 2 遍命中它 → `JSON.parse` **成功**（合法 JSON！）→ **不换线**
 *    ⇒ `content = ''` ⇒ **正文是空的** ⭐
 *
 * ────────────────────────────────────────────────────────────
 * ⭐⭐⭐ **新引擎下的等价语义**（2026-10-25 老 JS 引擎物理删除）
 *
 * 新引擎**没有两遍跑**：站方 JS 由**引擎同步执行**（同一条线程、同一个调用栈）
 *   ⇒ 「先录一遍、再抓一遍」那套补丁**整个不需要了**
 *   ⇒ **请求数 = 站方 catch 循环实际试了几次**（不是候选总数）⭐⭐⭐
 *
 * ⇒ **语义等价在哪**（老语义 ⇄ 新语义）：
 *   老语义「宿主按 path+query+method 归组 ⇒ 每组只抓第一个 ⇒ 不一股脑全抓」
 *   新语义「引擎同步跑站方 JS ⇒ 第一条线路成功 ⇒ 就只发 1 个请求；
 *             第一条挂了 ⇒ 站方 catch 循环**当场**换下一条 ⇒ 请求数 = 换线次数」
 *   ⇒ **可观测结果一致**：候选 3 条时，请求数都是 1~2 条，**绝不是 3 条** ⭐⭐⭐
 *   ⇒ 也就是说：**「互斥候选不会一次性全抓」这条语义在新引擎下依然成立**，
 *     而且是**更强**的成立（站方自己决定试几条，宿主不再替它猜）⭐⭐⭐
 *
 * ⚠️ 假服务器写法变了：老门禁用 JS 层的 `nativeMock`（async mock），
 *    现在是**声明式 routes**（下沉到 transport 层 ⇒ 引擎同步执行时也拦得到）⭐⭐⭐
 */
const { createSandbox, engineAvailable } = require('./new-engine-harness');

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
  if (!engineAvailable()) {
    console.log('  ⏭️  跳过：没编译 legado-engine ⇒ 本门禁没验到（**不等于通过**）');
    console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
    process.exit(fail ? 1 : 0);
  }

  // ──────────────────────────────────────────────
  // ① 同组候选（path 相同、host 不同）⇒ 只试到成功那一条
  // ──────────────────────────────────────────────
  console.log('=== ① 同组候选：第一条通 ⇒ 只发 1 个请求（回归：8 条全抓会打爆番茄限流）===');
  {
    const { win, sandbox } = createSandbox({
      routes: [
        { match: 'a.example.com', status: 200, body: '{"ok":1}' },
        { match: 'b.example.com', status: 200, body: '{"ok":2}' },
        { match: 'c.example.com', status: 200, body: '{"ok":3}' },
      ],
    });
    const hosts = ['https://a.example.com', 'https://b.example.com', 'https://c.example.com'];
    const r = win.QR.rule.runJs(candidateScript(hosts), {});

    const reqs = sandbox.__requests.filter(u => /\/p$/.test(u.split('?')[0]));
    console.log('  真实请求:', reqs.length, reqs.map(u => u.replace('https://', '')).join(' , '));
    console.log('  站方拿到:', JSON.stringify(String(r).slice(0, 40)));
    ok(reqs.length === 1,
       `同组 3 个候选只该试 1 个（实际 ${reqs.length} 个）—— 全抓会打爆站方限流`);
    ok(reqs[0] && reqs[0].indexOf('a.example.com') >= 0,
       '试的是第一个候选（base_url 那条）');
    ok(String(r).indexOf('"ok":1') >= 0, '站方最终拿到了内容');
  }

  // ──────────────────────────────────────────────
  // ② 第一个候选失败 ⇒ 站方自己换线 ⇒ 逐条试，不是一把梭
  // ──────────────────────────────────────────────
  console.log('\n=== ② 第一个候选失败 ⇒ 站方自己换线（逐条试）===');
  {
    const { win, sandbox } = createSandbox({
      routes: [
        // 第一条线路 502 ⇒ 站方 JSON.parse 抛 ⇒ 应当换下一条
        { match: 'a.example.com', status: 502, body: '<html>502</html>' },
        { match: 'b.example.com', status: 200, body: '{"ok":2}' },
        { match: 'c.example.com', status: 200, body: '{"ok":3}' },
      ],
    });
    const hosts = ['https://a.example.com', 'https://b.example.com', 'https://c.example.com'];
    const r = win.QR.rule.runJs(candidateScript(hosts), {});

    const reqs = sandbox.__requests.filter(u => /\/p$/.test(u.split('?')[0]));
    console.log('  真实请求:', reqs.length, reqs.map(u => u.replace('https://', '')).join(' , '));
    console.log('  站方拿到:', JSON.stringify(String(r).slice(0, 40)));
    ok(reqs.length === 2,
       `第一条 502 时应该**逐条换**（a 失败 → b 成功 ⇒ 2 个请求），实际 ${reqs.length} 个`);
    ok(reqs.some(u => u.indexOf('b.example.com') >= 0),
       '换到了第二条线路 b（站方的「自动切换」机制真的生效了）');
    ok(String(r).indexOf('"ok":2') >= 0, '站方拿到了第二条线路的响应');
  }

  // ──────────────────────────────────────────────
  // ③ 不同 path 的顺序链**不受影响**（浏览器 → 交接 那条链）
  // ──────────────────────────────────────────────
  console.log('\n=== ③ 不同 path 的顺序链照旧全发（不能被误伤）===');
  {
    const { win, sandbox } = createSandbox({
      routes: [
        { match: '/get_token', status: 200, body: '{"token":"T"}' },
        { match: '/handover', status: 200, body: '{"handover":"H"}' },
      ],
    });
    // 两个**不同 path** 的请求（模拟「先拿 token 再交接」的顺序链）
    const code = `
var a = java.ajax('https://x.example.com/get_token');
var b = java.ajax('https://x.example.com/handover');
a + '|' + b
`;
    win.QR.rule.runJs(code, {});
    const got = sandbox.__requests.map(u => u.split('/').pop());
    console.log('  真实请求:', got.join(' , '));
    ok(got.includes('get_token') && got.includes('handover'),
       '不同 path 的顺序链两个都要发（不能被误伤）');
  }

  // ──────────────────────────────────────────────
  // ④ 同样 path、但 **headers 不同** ⇒ 不是互斥候选，两个都要发
  //    （番茄登录链：browser 拿 sessionid → 交接 ajax 带 sessionid，
  //      两次 ajax 的 path/query/method 完全一样，只有 cookie 不同
  //      ⇒ 老宿主若按 path+query+method 归组 ⇒ 第二遍被判「已试过」⇒ 永远不重抓
  //      ⇒ `sessionid=undefined` ⇒ **番茄登录直接废掉** ⭐）
  // ──────────────────────────────────────────────
  console.log('\n=== ④ 同 path 但 headers 不同 ⇒ 两个都要发（番茄登录链）===');
  {
    const { win, sandbox } = createSandbox({
      routes: [{ match: 'x.example.com', status: 200, body: '{"ok":1}' }],
    });
    // 同一个 path，但 cookie 不同（模拟「拿到 sessionid 前后各一次」）
    // ⚠️ 必须用**字符串形式** `,{json}` —— 站方（Legado）就是这么写的
    const code = `
var a = java.ajax('https://x.example.com/api,{"headers":{"cookie":"sessionid=undefined"}}');
var b = java.ajax('https://x.example.com/api,{"headers":{"cookie":"sessionid=REAL"}}');
a + '|' + b
`;
    win.QR.rule.runJs(code, {});
    // ⭐ 沙盒里 Node 后端的静态路由拿到的是**站方原样传的 URL**（含 `,{json}` 后缀）
    //   ⇒ cookie 直接看得见；真机上引擎的 URLBuilder 会把它拆成 headers（method/body/headers）
    //   ⇒ 两条语义一致：**两次请求各带各的 cookie，不会被合并/丢掉**
    const reqs = sandbox.__requests;
    console.log('  真实请求:', reqs.length, reqs.map(u => (u.match(/sessionid=[A-Za-z]+/) || ['?'])[0]).join(' , '));
    ok(reqs.length === 2,
       `同 path、cookie 不同的两次请求都要发（实际 ${reqs.length} 次）—— 否则番茄登录拿到 undefined`);
    ok(reqs.some(u => u.indexOf('sessionid=REAL') >= 0),
       '带真 sessionid 的那次也发了（登录链的交接请求）');
    ok(reqs.some(u => u.indexOf('sessionid=undefined') >= 0),
       '带 undefined 的那次也发了（两遍各发各的 ⇒ 不是同一个请求）');
  }

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
