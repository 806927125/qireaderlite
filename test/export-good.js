/* 把实测可用的书源导出成可导入的文件
   跑法：node test/export-good.js */
const fs = require('fs');
const path = require('path');

const IN = process.argv[2] || '/tmp/live-good-all.json';
const OUT = process.argv[3] || '/workspace/可用书源';

if (!fs.existsSync(IN)) { console.error('没找到 ' + IN); process.exit(1); }
let good = JSON.parse(fs.readFileSync(IN, 'utf8'));

// 质量过滤：书名像真书名、作者像真作者
const junk = ['搜索', '作品名称', '更多', '首页', 'title', 'text', 'd-name', '返回', '浏览', '搜索结果'];
function quality(s) {
  const n = String(s.bookSourceName || '');
  const r = s.ruleSearch || {};
  return n && !junk.some((j) => n.trim() === j);
}

// 按站点去重
const bySite = new Map();
for (const s of good) {
  const k = String(s.bookSourceUrl || '').replace(/\/+$/, '');
  if (!bySite.has(k)) bySite.set(k, s);
}
let list = [...bySite.values()].filter(quality);
fs.mkdirSync(OUT, { recursive: true });

// 单个文件
list.forEach((s, i) => {
  const name = String(s.bookSourceName || ('源' + i)).replace(/[\\/:*?"<>|]/g, '_').slice(0, 28);
  const f = path.join(OUT, `${String(i + 1).padStart(2, '0')}-${name}.json`);
  fs.writeFileSync(f, JSON.stringify(s, null, 1), 'utf8');
});

// 合集：一次全导
fs.writeFileSync(path.join(OUT, '合集-一次全导.json'), JSON.stringify(list, null, 1), 'utf8');

console.log('导出 ' + list.length + ' 个源到 ' + OUT);
list.forEach((s, i) => {
  const name = String(s.bookSourceName || '').replace(/[\\/:*?"<>|]/g, '_').slice(0, 28);
  console.log('  ' + String(i + 1).padStart(2) + '. ' + name.padEnd(30) + s.bookSourceUrl);
});
