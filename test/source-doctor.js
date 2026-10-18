/* 书源体检：拿一份真实书源，静态预判它在轻阅（JSC）上会挂在哪
   跑法：node test/source-doctor.js <书源.json> [更多.json...]

   为什么需要这个（2026-10-18 用户反馈「移植了也不见得我的书源能用」）：
     移植 packages_stub 只证明「Java 类那一层有了」，
     但书源能不能跑，取决于它用到的 java.* / org.jsoup / Rhino 方言 / @js: 返回值形状
     —— 这些跟 packages_stub 是**两回事**，必须单独验。
     而且这些大多是**静态**就能看出来的问题，不用联网、不用真机。

   ⚠️ 本工具**只做静态预判**，输出「疑似问题」而不是定论：
     最终结论要以真机 / 沙盒跑规则为准。 */
const fs = require('fs');
const path = require('path');

const ENGINE_DIR = path.join(__dirname, '..', 'QiReaderLite', 'Resources', 'engine');

/* ── 轻阅现有能力（从 java-api.js / org-jsoup.js 实测提取，别手抄） ── */
function harvestImplementations() {
  const java = new Set();
  const org = new Set();
  const scan = (file) => {
    const s = fs.readFileSync(path.join(ENGINE_DIR, file), 'utf8');
    // java-api.js 的 java 对象字面量方法
    if (file === 'java-api.js') {
      const body = s.slice(s.indexOf('g.java = g.java || {}'));
      for (const m of body.matchAll(/^\s{4}([a-zA-Z_$][\w$]*)\s*:\s*function/gm)) java.add(m[1]);
      for (const m of body.matchAll(/^\s{4}([a-zA-Z_$][\w$]*)\s*:\s*function\s*\(/gm)) java.add(m[1]);
    }
    if (file === 'org-jsoup.js') {
      // El.prototype.x / Elements.prototype.x / Jsoup.x / g.org.x
      for (const m of s.matchAll(/([A-Za-z_$][\w$]*)\.prototype\.([a-zA-Z_$][\w$]*)\s*=/g)) org.add(m[2]);
      for (const m of s.matchAll(/^\s{2,4}([a-zA-Z_$][\w$]*)\s*:\s*function/gm)) org.add(m[1]);
    }
  };
  scan('java-api.js');
  scan('org-jsoup.js');
  return { java, org };
}

const IMPL = harvestImplementations();

/* packages_stub.js 新增的 Java 类（移植后才有的） */
function packagesClasses() {
  const s = fs.readFileSync(path.join(ENGINE_DIR, 'packages_stub.js'), 'utf8');
  const set = new Set();
  for (const m of s.matchAll(/Packages\.((?:java|javax|cn|com|io|org)[\w.]*)/g)) set.add(m[1]);
  return set;
}
const PKG = packagesClasses();

/* ── 收集书源里所有会执行 JS 的字段 ── */
const JS_FIELDS = [
  'jsLib',
  'ruleSearch.searchUrl', 'ruleSearch.bookList', 'ruleSearch.name', 'ruleSearch.author',
  'ruleSearch.intro', 'ruleSearch.kind', 'ruleSearch.lastChapter', 'ruleSearch.bookUrl',
  'ruleExplore.exploreUrl', 'ruleExplore.bookList', 'ruleExplore.name', 'ruleExplore.author',
  'ruleExplore.intro', 'ruleExplore.kind', 'ruleExplore.lastChapter', 'ruleExplore.bookUrl',
  'ruleBookInfo.name', 'ruleBookInfo.author', 'ruleBookInfo.intro', 'ruleBookInfo.kind',
  'ruleBookInfo.lastChapter', 'ruleBookInfo.coverUrl', 'ruleBookInfo.tocUrl',
  'ruleToc.chapterList', 'ruleToc.chapterName', 'ruleToc.chapterUrl',
  'ruleToc.nextTocUrl', 'ruleContent.content', 'ruleContent.nextContentUrl',
  'ruleSearch.nextUrl', 'ruleExplore.nextUrl', 'ruleToc.nextTocUrl',
];

function dig(obj, dotted) {
  return dotted.split('.').reduce((o, k) => (o == null ? undefined : o[k]), obj);
}

function hasJsMarker(v) {
  const s = String(v == null ? '' : v);
  return s.includes('@js:') || /<js[\s>]/i.test(s);
}

/* Rhino 方言检测 */
const RHINO_TELLS = [
  { re: /(^|[;{}\s])return[\s]/m, why: '顶层 return（Rhino 方言）', risk: 'high' },
  { re: /(^|[^.\w])print\s*\(/m, why: 'Rhino 的 print()', risk: 'low' },
  { re: /\[\s*\w+\s*,\s*\w+\s*\]\s*=>/m, why: '解构参数不带括号（Rhino 宽松语法）', risk: 'mid' },
  { re: /\bo\.get\w+\(|\bjava\.util\./m, why: 'Rhino 特有全局', risk: 'mid' },
];

function analyze(files) {
  const problems = [];
  const notes = [];
  const usedJava = new Set();
  const usedOrg = new Set();

  for (const file of files) {
    let src;
    const raw = fs.readFileSync(file, 'utf8');
    try { src = JSON.parse(raw); }
    catch (e) {
      // 可能是 JSON 数组或带 BOM
      try { src = JSON.parse(raw.replace(/^﻿/, '')); }
      catch (e2) { problems.push({ f: file, sev: 'err', msg: 'JSON 解析失败: ' + e2.message }); continue; }
    }
    const sources = Array.isArray(src) ? src : [src];

    for (const s of sources) {
      const name = s.bookSourceName || '(无名)';
      const url = s.bookSourceUrl || '(无 url)';

      /* 1. 哪些字段执行 JS */
      const jsFields = JS_FIELDS.filter((f) => hasJsMarker(dig(s, f)));
      if (jsFields.length) {
        notes.push(`${name}: ${jsFields.length} 个字段带 @js:/<js>`);
      }

      /* 2. chapterUrl 里塞 JS —— JSContextPool 死锁高发区 */
      const cu = String(dig(s, 'ruleToc.chapterUrl') || '');
      if (hasJsMarker(cu)) {
        problems.push({
          f: name, sev: 'high',
          msg: 'ruleToc.chapterUrl 里塞了 JS —— 每章并发跑 JS，'
             + 'iOS 15s 硬中断 / 安卓 JSContextPool(16) 会死锁，表现为"目录只出第一章"。'
             + '修法：把 URL 在 chapterList 阶段算好塞进元素，chapterUrl 写 $.url（每章 0 次 JS）',
        });
      }

      /* 3. @js: 返回裸对象 —— 后续 $.xxx 会走不通 */
      const allJs = JS_FIELDS.map((f) => String(dig(s, f) || '')).join('\n')
        + '\n' + String(s.jsLib || '');
      if (/out\.push\(\s*\{\s*\w+\s*:/.test(allJs) || /\.push\(\{\s*"?[a-zA-Z_]+"?\s*:/g.test(allJs)) {
        if (!/JSON\.stringify/.test(allJs)) {
          problems.push({
            f: name, sev: 'high',
            msg: '规则里出现 out.push({...}) 裸对象、且没看到 JSON.stringify —— '
               + '在 Rhino 上对象会被当 NativeObject，后续 $.xxx 裸键访问；'
               + '在 JSC 上返回的是真 JS 对象，行为可能不一致。建议统一 out.push(JSON.stringify(item))，'
               + '并把 book_url/chapter_url 拼在元素上。',
          });
        }
      }

      /* 4. 用了哪些 java.* / org.jsoup.*，轻阅有没有 */
      const jsSrc = [s.jsLib, ...JS_FIELDS.map((f) => dig(s, f))].filter(Boolean).map(String).join('\n');
      for (const m of jsSrc.matchAll(/\bjava\.([a-zA-Z_$][\w$]*)/g)) usedJava.add(m[1]);
      for (const m of jsSrc.matchAll(/\borg\.jsoup\.([A-Za-z_$][\w$]*)/g)) usedOrg.add(m[1]);
      for (const m of jsSrc.matchAll(/\bJsoup\.([a-zA-Z_$][\w$]*)/g)) usedOrg.add('Jsoup.' + m[1]);

      /* 5. Rhino 方言 */
      for (const t of RHINO_TELLS) {
        if (t.re.test(jsSrc)) {
          problems.push({ f: name, sev: t.risk === 'high' ? 'mid' : 'low',
            msg: `疑似${t.why} —— Rhino 收，iOS 的 JavaScriptCore 可能报语法错` });
        }
      }

      /* 6. URL 的 ,{headers} 语法 */
      for (const f of ['ruleSearch.searchUrl', 'ruleExplore.exploreUrl', 'ruleToc.nextTocUrl']) {
        const v = String(dig(s, f) || '');
        if (/,\s*\{/.test(v)) {
          notes.push(`${name}: ${f} 用了 ,{"headers":…} 语法（逗号后 JSON 替换源级 header，逗号前别留空格）`);
        }
      }
    }
  }

  /* 7. java.* / org 缺口 */
  const javaMissing = [...usedJava].filter((m) => !IMPL.java.has(m)).sort();
  const orgMissing = [...usedOrg].filter((m) => !IMPL.org.has(m.split('.')[1] || m)).sort();

  return { problems, notes, usedJava: [...usedJava].sort(), javaMissing, orgMissing };
}

const files = process.argv.slice(2);
if (!files.length) {
  console.log('用法：node test/source-doctor.js <书源.json> [更多.json...]');
  console.log('');
  console.log('轻阅现有 java.* 方法（' + IMPL.java.size + ' 个）：');
  console.log('  ' + [...IMPL.java].sort().join(' '));
  console.log('');
  console.log('轻阅现有 org.jsoup.* 成员（' + IMPL.org.size + ' 个）：');
  console.log('  ' + [...IMPL.org].sort().join(' '));
  console.log('');
  console.log('packages_stub 补的 Java 类（' + PKG.size + ' 个）：');
  console.log('  ' + [...PKG].slice(0, 40).sort().join('\n  '));
  process.exit(0);
}

const r = analyze(files);
console.log('══ 书源体检 ══\n');
if (r.notes.length) { console.log('【说明】'); r.notes.forEach((n) => console.log('  · ' + n)); console.log(''); }
if (r.problems.length) {
  console.log('【疑似问题】');
  const order = { err: 0, high: 1, mid: 2, low: 3 };
  r.problems.sort((a, b) => order[a.sev] - order[b.sev]);
  r.problems.forEach((p) => {
    console.log('  ' + (p.sev === 'high' ? '🔴' : p.sev === 'mid' ? '🟡' : p.sev === 'err' ? '⛔' : '⚪')
      + ' [' + p.sev + '] ' + (p.f || '') + '\n      ' + p.msg);
  });
  console.log('');
}
console.log('【API 覆盖】');
console.log('  书源用到 java.*：' + (r.usedJava.join(' ') || '(无)'));
console.log('  轻阅没有的：' + (r.javaMissing.length ? r.javaMissing.join(' ') : '无 ✓'));
console.log('  书源用到 org.jsoup.*：' + (r.usedOrg.join(' ') || '(无)'));
console.log('  轻阅没有的：' + (r.orgMissing.length ? r.orgMissing.join(' ') : '无 ✓'));
