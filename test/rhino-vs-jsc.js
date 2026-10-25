/* 找出 Rhino（Legado 的 JS 引擎）能过、但 JavaScriptCore（iOS）过不了的语法
   跑法：node test/rhino-vs-jsc.js */
const fs = require('fs');
const path = require('path');
const { createSandbox } = require('./new-engine-harness');

const DIR = process.env.LEGADO_DIR || '/tmp/legado/sources';
const { QR } = createSandbox();

/** 用引擎自己的切分逻辑，把规则里真正属于 JS 的部分抠出来 */
function jsParts(rule) {
  if (rule == null) return [];
  const out = [];
  if (typeof rule === 'string') {
    const t = rule.trim();
    if (/^@js:/i.test(t)) { out.push(t.replace(/^@js:/i, '')); return out; }
    if (/^<js>/i.test(t)) { out.push(t.replace(/^<js>/i, '').replace(/<\/js>$/i, '')); return out; }
    // 规则中间的 <js> 段
    const re = /<js>([\s\S]*?)<\/js>/gi;
    let m;
    while ((m = re.exec(rule)) !== null) out.push(m[1]);
    return out;
  }
  if (Array.isArray(rule)) {
    for (const r of rule) out.push(...jsParts(r));
    return out;
  }
  return out;
}

const errs = new Map();   // 错误消息 → {count, sample}
let total = 0, bad = 0;

function scanAll() {
  for (const f of fs.readdirSync(DIR).filter((x) => x.endsWith('.json'))) {
    let d;
    try { d = JSON.parse(fs.readFileSync(path.join(DIR, f), 'utf8')); } catch (e) { continue; }
    for (const s of (Array.isArray(d) ? d : [d])) {
      if (!s || typeof s !== 'object') continue;
      const blobs = [];
      for (const [field, val] of Object.entries(s)) {
        if (field === 'bookSourceName' || field === 'bookSourceUrl' || field === 'bookSourceGroup') continue;
        if (field === 'exploreUrl' || field === 'jsLib' || field === 'loginUrl' || field === 'loginCheckJs') {
          blobs.push([field, val]);
        } else if (field.startsWith('rule')) {
          const r = s[field];
          if (r && typeof r === 'object') {
            for (const [k, v] of Object.entries(r)) blobs.push([field + '.' + k, v]);
          }
        }
      }
      for (const [field, raw] of blobs) {
        for (const code of jsParts(raw)) {
          if (!code.trim()) continue;
          total++;
          try { new Function('return (function(){' + code + '\n})'); }
          catch (e) {
            bad++;
            const key = String(e.message).split('\n')[0].slice(0, 60);
            if (!errs.has(key)) errs.set(key, { count: 0, sample: { name: s.bookSourceName, field, code } });
            errs.get(key).count++;
          }
        }
      }
    }
  }
}

scanAll();
console.log('JS 片段 ' + total + ' 个，语法错 ' + bad + ' 个 = ' + (bad / total * 100).toFixed(2) + '%\n');
console.log('=== 按错误类型分组 ===');
[...errs.entries()].sort((a, b) => b[1].count - a[1].count).forEach(([msg, v]) => {
  console.log('\n■ ' + msg + '  （' + v.count + ' 处）');
  console.log('  来源: ' + v.sample.name + ' / ' + v.sample.field);
  console.log('  代码: ' + v.sample.code.replace(/\s+/g, ' ').slice(0, 150));
});
