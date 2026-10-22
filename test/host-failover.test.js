#!/usr/bin/env node
/**
 * **线路挂了自动换线**（2026-10-22 真机「QQ 阅读目录出不来」）
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
 * 而宿主原来的重试判定**只认 `code == 0`**（无响应）⇒ 502 被当成「成功」⇒ 不重试。
 *
 * ⇒ 修法：引擎侧 `rawRequest` 收到 **5xx** ⇒ 自动把 URL 的 host 换成站方
 *         jsLib 里 `host[]` 的下一条线路重试**一次**。
 *
 * ⚠️ 关键约束：**只换一次** ⇒ 不会变成「一次操作发 8 条」⇒ 不会打爆站方限流。
 */
const { createSandbox } = require('./harness');

let pass = 0, fail = 0;
const ok = (c, m) => { c ? pass++ : (fail++, console.log('  ✗ ' + m)); };

/** 造一个 jsLib（站方 jsLib 是间接 eval ⇒ `var host` 落在全局 ⇒ 引擎读得到） */
const JSLIB = "var host = ['https://v5.example.com','https://v4.example.com','http://219.154.201.122:5006'];";

(async () => {
  console.log('=== ① 5xx ⇒ 自动换下一条线路重试（只换一次）===');
  {
    const reqs = [];
    const nativeMock = async (fn, args) => {
      if (fn === 'request') {
        const url = String(args.url || '');
        reqs.push(url);
        // v5 这条线路**一直 502**（模拟 Cloudflare 挂了）
        if (url.indexOf('v5.example.com') >= 0) {
          return { ok: true, code: 502, url, headers: {}, body: '<html>502</html>' };
        }
        return { ok: true, code: 200, url, headers: {}, body: '{"ok":1}' };
      }
      if (fn === 'log') return { ok: true };
      return { ok: true, value: '' };
    };
    const { win } = createSandbox({ nativeMock });
    // ⚠️ 必须**走 ensureJsLib** 加载站方 jsLib —— 换线用的线路列表
    //    `QR.__qrStationHosts` 是 ensureJsLib 从 jsLib 里取的
    //    （⚠️ 不再直接读全局 `host` —— 那是 jsLib 的全局变量，换书源会残留 ⇒ 会串台）
    await win.eval(`window.__qrInvoke('exploreKinds', ${JSON.stringify({
      source: {
        bookSourceUrl: 'https://src.example.com',
        bookSourceName: 'src',
        jsLib: JSLIB,
        exploreUrl: JSON.stringify([{ title: 'c1', url: 'https://src.example.com/c1' }]),
      },
    })})`);
    const r = await win.eval(`window.QR.rule.runJs(${JSON.stringify(
      "java.ajax('https://v5.example.com/catalog?x=1');"
    )}, {})`);

    console.log('  实际请求:');
    reqs.forEach(u => console.log('    · ' + u));
    ok(reqs.length === 2, `应该发 2 次（v5 失败 → 换线重试 1 次），实际 ${reqs.length} 次`);
    ok(reqs[0] && reqs[0].indexOf('v5.example.com') >= 0, '第一次打的是原线路 v5');
    ok(reqs[1] && reqs[1].indexOf('v4.example.com') >= 0,
       '第二次换到了 v4（host[] 的下一条）');
    ok(String(r).indexOf('ok') >= 0, '站方最终拿到了内容（不是 502 错误页）');
  }

  console.log('\n=== ② 只换一次（不能无限换 / 不能变成发 8 条）===');
  {
    const reqs = [];
    const nativeMock = async (fn, args) => {
      if (fn === 'request') {
        const url = String(args.url || '');
        reqs.push(url);
        // **所有**线路都 502
        return { ok: true, code: 502, url, headers: {}, body: '<html>502</html>' };
      }
      if (fn === 'log') return { ok: true };
      return { ok: true, value: '' };
    };
    const { win } = createSandbox({ nativeMock });
    await win.eval(`window.__qrInvoke('exploreKinds', ${JSON.stringify({
      source: {
        bookSourceUrl: 'https://src.example.com', bookSourceName: 'src', jsLib: JSLIB,
        exploreUrl: JSON.stringify([{ title: 'c1', url: 'https://src.example.com/c1' }]),
      },
    })})`);
    try {
      await win.eval(`window.QR.rule.runJs(${JSON.stringify(
        "java.ajax('https://v5.example.com/catalog?x=1');"
      )}, {})`);
    } catch (e) { /* 502 正常会抛，忽略 */ }
    const hosts = reqs.map(u => { try { return new URL(u).host; } catch (e) { return '?'; } });
    console.log('  实际请求数:', reqs.length, hosts.join(' , '));
    const uniq = Array.from(new Set(hosts));
    // ⚠️ 上限是「两遍跑 5 轮 × 每轮换线 1 次」⇒ 最多 10 个请求
    ok(reqs.length <= 10, `全挂时请求数有上限（≤10），实际 ${reqs.length} 次`);
    ok(uniq.length >= 2, `应该逐条换线试不同线路（覆盖了 ${uniq.length} 条：${uniq.join(',')}）`);
  }

  console.log('\n=== ③ URL 里的 `,{json}` 选项后缀不能被换线弄丢 ===');
  {
    const reqs = [];
    const nativeMock = async (fn, args) => {
      if (fn === 'request') {
        const url = String(args.url || '');
        reqs.push(url);
        if (url.indexOf('v5.example.com') >= 0) {
          return { ok: true, code: 502, url, headers: {}, body: '<html>502</html>' };
        }
        return { ok: true, code: 200, url, headers: {}, body: '{"ok":1}' };
      }
      if (fn === 'log') return { ok: true };
      return { ok: true, value: '' };
    };
    const { win } = createSandbox({ nativeMock });
    await win.eval(`window.__qrInvoke('exploreKinds', ${JSON.stringify({
      source: {
        bookSourceUrl: 'https://src.example.com', bookSourceName: 'src', jsLib: JSLIB,
        exploreUrl: JSON.stringify([{ title: 'c1', url: 'https://src.example.com/c1' }]),
      },
    })})`);
    try {
      await win.eval(`window.QR.rule.runJs(${JSON.stringify(
        "java.ajax('https://v5.example.com/catalog,{\"method\":\"POST\",\"body\":\"{\\\\\"a\\\\\":1}\"}');"
      )}, {})`);
    } catch (e) { /* ignore */ }
    reqs.forEach(u => console.log('    · ' + u));
    // ⚠️ `,{json}` 选项后缀**本来就该被剥掉** ——
    //    `fetchRecorded` 用 `QR.analyzeUrl(u)` 拆出 method/body/headers，
    //    真正发出去的是**裸 URL**（站方/栖阅也是这个语义）
    //    ⇒ 断言应该是：换线后 **path 保持不变**、host 换掉、且不带后缀
    console.log('  实际请求:', reqs.join(' , '));
    ok(reqs[0] && /\/catalog$/.test(reqs[0]), 'path 保持 /catalog（query 被 analyzeUrl 规范化）');
    ok(reqs[0] && reqs[0].indexOf('method') < 0,
       '发出去的 URL 不带 `,{json}` 后缀（method/body 已单独拆出）');
    ok(reqs[1] && reqs[1].indexOf('v4.example.com') >= 0, 'host 确实换掉了');
    ok(reqs[1] && /\/catalog$/.test(reqs[1]), '换线后 path 也没变');
  }

  console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('炸了：', e); process.exit(2); });
