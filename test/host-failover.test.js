#!/usr/bin/env node
/**
 * **线路挂了要能换线**（2026-10-22 真机「QQ 阅读目录出不来」）
 *
 * 跑法：node test/host-failover.test.js
 *
 * ────────────────────────────────────────────────────────────
 * 背景
 *
 * 实测：`v5.langge.uk/catalog?source=svip_QQ阅读` **一直返 502**（Cloudflare 错误页）
 * ⇒ 站方的 `ruleToc.chapterList` **没有 catch 换线兜底**（只有 `detail` 规则有）
 * ⇒ 目录解析失败 ⇒ **0 章**
 *
 * 老宿主（老 JS 引擎）的修法：**引擎侧 `rawRequest` 收到 5xx**
 *   ⇒ 自动把 URL 的 host 换成站方 jsLib 里 `host[]` 的下一条线路**重试一次**
 *   ⇒ 关键约束：**只换一次** ⇒ 不会变成「一次操作发 8 条」⇒ 不会打爆站方限流。
 *
 * ────────────────────────────────────────────────────────────
 * ⭐⭐⭐ **新引擎下的等价语义**（2026-10-25 老 JS 引擎物理删除）
 *
 * 新引擎**没有「宿主侧自动换线」这层补丁**了 ⇒ 换线由**两处**承担：
 *   ① **站方自己的 catch 循环**（引擎**同步**执行站方 JS ⇒ 换线是**当场**发生的）
 *      ⇒ **请求数 = 换线次数**（不是候选总数）⭐⭐⭐
 *   ② **宿主侧「先测速挑一条通的」**（`ensureFastLine`）
 *      ⇒ 进页面先把最快的一条线路写进站方 `server` 变量 ⇒ 站方**只走那一条**
 *      ⇒ 每个 op 一次请求 ⇒ 死线路不会挨个等超时（🍅大灰狼 8 条线路的老坑）
 *
 * ⇒ **语义等价在哪**（老语义 ⇄ 新语义）：
 *   老语义「5xx ⇒ 宿主自动换下一条线路重试一次（只换一次）」
 *   新语义「5xx ⇒ 站方 catch 循环**当场**换下一条 ⇒ 请求数 = 换线次数；
 *             ＋ 宿主**先测速**挑一条通的 ⇒ 正常情况下根本不会撞上死线路」
 *   ⇒ 可观测结果一致：**线路挂了就换一条继续跑，不会 0 章 / 不会一次发 8 条** ⭐⭐⭐
 *
 * ⚠️ 假服务器写法变了：老门禁用 JS 层的 `nativeMock`（async mock），
 *    现在是**声明式 routes**（下沉到 transport 层 ⇒ 引擎同步执行时也拦得到）⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');
const { createSandbox, engineAvailable } = require('./new-engine-harness');
const { analyzeUrl, engineSwiftSrc } = require('./engine-gate-helpers.js');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

/** 站方 jsLib（线路数组在站方自己手里 ⇒ 换线/测速都以它为准） */
const JSLIB = "var host = ['https://v5.example.com','https://v4.example.com','http://219.154.201.122:5006'];";

/** 站方脚本：catch 循环换线（老引擎时代由宿主代劳，现在由站方当场做） */
function failoverScript(urls) {
  return `
var urls = ${JSON.stringify(urls)};
var out = '';
for (var i = 0; i < urls.length; i++) {
  try {
    out = java.ajax(urls[i]);
    JSON.parse(out);
    break;
  } catch (e) { /* 这条线路挂了 ⇒ 换下一条 */ }
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

  console.log('=== ① 5xx ⇒ 站方 catch 循环当场换下一条线路（只换到成功那条）===');
  {
    const { win, sandbox } = createSandbox({
      routes: [
        // v5 这条线路**一直 502**（模拟 Cloudflare 挂了）
        { match: 'v5.example.com', status: 502, body: '<html>502</html>' },
        { match: 'v4.example.com', status: 200, body: '{"ok":1}' },
        { match: '219.154.201.122', status: 200, body: '{"ok":9}' },
      ],
    });
    const urls = [
      'https://v5.example.com/catalog?x=1',
      'https://v4.example.com/catalog?x=1',
      'http://219.154.201.122:5006/catalog?x=1',
    ];
    const r = String(win.QR.rule.runJs(failoverScript(urls), {}));

    console.log('  实际请求:');
    sandbox.__requests.forEach(u => console.log('    · ' + u));
    ok(sandbox.__requests.length === 2,
       `应该发 2 次（v5 失败 → 换线到 v4），实际 ${sandbox.__requests.length} 次`);
    ok(sandbox.__requests[0] && sandbox.__requests[0].indexOf('v5.example.com') >= 0,
       '第一次打的是原线路 v5');
    ok(sandbox.__requests[1] && sandbox.__requests[1].indexOf('v4.example.com') >= 0,
       '第二次换到了 v4（host[] 的下一条）');
    ok(r.indexOf('"ok":1') >= 0, '站方最终拿到了内容（不是 502 错误页）');
  }

  console.log('\n=== ② 只换到成功那条就停（不能无限换 / 不能变成发 8 条）===');
  {
    const { win, sandbox } = createSandbox({
      routes: [
        // **所有**线路都 502
        { match: 'v5.example.com', status: 502, body: '<html>502</html>' },
        { match: 'v4.example.com', status: 502, body: '<html>502</html>' },
        { match: '219.154.201.122', status: 502, body: '<html>502</html>' },
      ],
    });
    const urls = [
      'https://v5.example.com/catalog?x=1',
      'https://v4.example.com/catalog?x=1',
      'http://219.154.201.122:5006/catalog?x=1',
    ];
    String(win.QR.rule.runJs(failoverScript(urls), {}));
    const hosts = sandbox.__requests.map(u => { try { return new URL(u).host; } catch (e) { return '?'; } });
    console.log('  实际请求数:', sandbox.__requests.length, hosts.join(' , '));
    const uniq = Array.from(new Set(hosts));
    ok(sandbox.__requests.length === 3,
       `全挂时逐条试完 3 条就停（实际 ${sandbox.__requests.length} 次）—— 不能无限换`);
    ok(uniq.length === 3,
       `应该逐条换线试不同线路（覆盖了 ${uniq.length} 条：${uniq.join(',')}）`);
    ok(sandbox.__requests.length <= 3,
       '请求数有上限（不会变成「一次操作发 8 条」把站方限流打爆）');
  }

  console.log('\n=== ③ URL 里的 `,{json}` 选项后缀：换线不能弄丢 path，选项要被拆成 method/body ===');
  {
    const suffix = ',\\{"method":"POST","body":"{\\\\"a\\\\":1}"\\}';
    const urlV5 = 'https://v5.example.com/catalog' + suffix;
    const urlV4 = 'https://v4.example.com/catalog' + suffix;
    const { win, sandbox } = createSandbox({
      routes: [
        { match: 'v5.example.com', status: 502, body: '<html>502</html>' },
        { match: 'v4.example.com', status: 200, body: '{"ok":1}' },
      ],
    });
    String(win.QR.rule.runJs(failoverScript([urlV5, urlV4]), {}));
    const reqs = sandbox.__requests;
    console.log('  实际请求:', reqs.join(' , '));
    ok(reqs.length === 2, `换线后一共 2 个请求（实际 ${reqs.length} 个）`);
    ok(reqs[0] && reqs[0].split(',')[0].endsWith('/catalog'),
       '换线前 path 保持 /catalog（后缀只是选项，不是路径的一部分）');
    ok(reqs[1] && reqs[1].split(',')[0].endsWith('/catalog'),
       '换线后 path 也没变（只换 host）');
    ok(reqs[1] && reqs[1].indexOf('v4.example.com') >= 0, 'host 确实换掉了');
    // ⭐⭐⭐ **`,{json}` 选项必须被引擎的 URL 规则解析拆出来**（method/body/headers）
    //   ⇒ 真正发出去的是**裸 URL**（站方/栖阅也是这个语义）
    //   ⇒ 这一条用引擎的 `URLBuilder`（`--analyzeUrl`）验 ⇒ 不用猜
    const u = analyzeUrl({ url: 'https://v5.example.com/catalog,{"method":"POST","body":"{\\"a\\":1}"}' });
    ok(u && u.url === 'https://v5.example.com/catalog',
       `发出去的 URL 不带 ` + "`,{json}`" + ` 后缀（实际 ${u && u.url}）`);
    ok(u && u.method === 'POST', `method 被拆出来（实际 ${u && u.method}）`);
    ok(u && String(u.body).indexOf('"a"') >= 0, `body 被拆出来（实际 ${u && u.body}）`);
  }

  console.log('\n=== ④ 宿主侧「先测速挑一条通的」（新架构对「宿主自动换线」的等价物）===');
  {
    // ⭐ 语义等价：老宿主是「发请求失败后再换线」；新架构是「**进页面先测速**」
    //   ⇒ 站方 `server` 变量里就是一条**通的**线路 ⇒ 每个 op 只打那一条 ⇒ 不卡
    const svc = fs.readFileSync(
      path.join(__dirname, '..', 'QiReaderLite', 'Core', 'SourceService.swift'), 'utf8');
    const tools = fs.readFileSync(
      path.join(__dirname, '..', 'QiReaderLite', 'Core', 'HostTools.swift'), 'utf8');
    ok(/func ensureFastLine\(source: BookSource/.test(svc), '有 ensureFastLine（先测速挑一条通的）');
    ok(/sourceHosts\(source: source\)/.test(svc),
       '测速的线路来自**站方 jsLib 的 host[]**（不是宿主自己猜的）');
    ok(/pingHosts\(hosts/.test(svc), '真的去测速了（并发 ping）');
    ok(/let payload = .*server/.test(svc),
       '选中的线路写进站方的 `server` 变量（站方只走那一条）');
    ok(/mergeVars\(userJSON: payload, defaults: defaults\)/.test(svc),
       '写 `server` 时**以站方默认表做底**（别把 tab/sources/proxy 写丢）');
    ok(/setVars\(merged, for: source\.bookSourceUrl\)/.test(svc),
       '写进书源变量（站方 `getArguments("server")` 读得到）');
    ok(/func pingHosts\(_ hosts: \[String\]/.test(tools), '有 pingHosts（并发测速一组线路）');
    ok(/timeoutIntervalForRequest = timeout/.test(tools),
       '测速有超时上限（死线路不会干等）');
    // ⭐ 线路列表的来源：引擎的 `sourceHosts()` 读的是**站方 jsLib 的全局 `host`**
    const se = engineSwiftSrc('Pipeline/SourceEngine.swift');
    ok(/public func sourceHosts\(\) throws -> \[String\]/.test(se), '引擎有 sourceHosts（站方的线路列表）');
    ok(/typeof host !== 'undefined'/.test(se),
       "sourceHosts 读的是站方 jsLib 定义的**全局 host**（站方自己的线路）");
  }

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
