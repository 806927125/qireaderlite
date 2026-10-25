/* 用诊断拿到的**真实 HTML 片段**造测试页，验证新写的规则
   跑法：node test/rouwenwu-verify.js */
const { createSandbox } = require('./new-engine-harness');
const fs = require('fs');

// ↓ 这段结构是从 App 诊断里原样抄出来的（肉文屋 m.powenxue15.com 的书单条目）
const ITEMS = [
  { id: '122448', name: '畸恋', intro: '【骨科，乡村风，非处，重口味，偶尔有 np情节，小清新请慎重入坑】姜美红和孙家旺结婚十年，有一儿一女，在村子里住着豪华的二层小洋楼…', author: '异梦', state: '连载中', words: '16万字' },
  { id: '135656', name: '撬人墙角是要遭报应的（np 强制爱）', intro: '简介内容占位…', author: '青衫落拓', state: '完结', words: '42万字' },
  { id: '136415', name: '孤屿之舟（还想不告而别？再跑一个试试！1v1)', intro: '另一本简介…', author: '沉舟', state: '连载中', words: '8万字' }
];

function itemHTML(it) {
  return `<dl>` +
    `<a href="/info/${it.id}.html" class="cover" title="${it.name}">` +
    `<img class="lazy" src="/static/biqugewap/nocover.jpg" ` +
    `data-original="https://img.powenxue15.com/image/${it.id.slice(0,3)}/${it.id}/${it.id}s.jpg" ` +
    `alt="${it.name}"></a>` +
    `<dt><a href="/info/${it.id}.html" title="${it.name}">${it.name}</a></dt>` +
    `<dd>${it.intro}</dd>` +
    `<dd><a href="/author/${encodeURIComponent(it.author)}">${it.author}</a>` +
    `<span>${it.state}</span><span>${it.words}</span></dd>` +
    `</dl>`;
}

const PAGE = `<!DOCTYPE html><html lang="zh"><head><meta charset="UTF-8">` +
  `<title>都市言情小说-都市言情小说大全-PO文学</title></head><body>` +
  `<ul><li><a href="/sort/1/">全部小说</a></li><li><a href="/sort/2/">玄幻</a></li></ul>` +
  ITEMS.map(itemHTML).join('') +
  `</body></html>`;

/* 新写的规则：书单是 dl，书名在 dt 里的 a，简介是第 1 个 dd，作者在第 2 个 dd 的 a 里 */
const RULE_EXPLORE = {
  bookList: 'dl',
  name: 'dt a@text',
  bookUrl: 'dt a@href',
  coverUrl: 'img@data-original',
  intro: 'tag.dd.0@text',
  author: 'tag.dd.1@tag.a@text',
  kind: 'tag.dd.1@tag.span.0@text',
  wordCount: 'tag.dd.1@tag.span.1@text',
  lastChapter: ''
};

const SRC = {
  bookSourceUrl: 'https://m.powenxue15.com',
  bookSourceName: '肉文屋（规则修复版）',
  bookSourceGroup: '测试',
  enabled: true,
  enabledExplore: true,
  exploreUrl: '[{"title":"全部小说","url":"/sort/1/{{page}}/"},' +
    '{"title":"玄幻","url":"/sort/xuanhuan/{{page}}/"},' +
    '{"title":"武侠","url":"/sort/wuxia/{{page}}/"},' +
    '{"title":"都市","url":"/sort/dushi/{{page}}/"},' +
    '{"title":"穿越","url":"/sort/chuanyue/{{page}}/"},' +
    '{"title":"科幻","url":"/sort/kehuan/{{page}}/"}]',
  ruleExplore: RULE_EXPLORE
};

let pass = 0, fail = 0; const fails = [];
function eq(name, a, b) {
  if (JSON.stringify(a) === JSON.stringify(b)) { pass++; return; }
  fail++; fails.push(`${name}\n    期望 ${JSON.stringify(b)}\n    实际 ${JSON.stringify(a)}`);
}

const { win } = createSandbox();
win.webkit.messageHandlers.qr.postMessage = function (m) {
  if (m.fn === 'request') {
    const body = m.args.url.indexOf('/sort/') >= 0 ? PAGE : '';
    Promise.resolve(body ? { ok: true, code: 200, url: m.args.url, headers: {}, body: body, bytes: body.length }
                          : { ok: false, error: '404' })
      .then((v) => win.__qrResolve(m.id, v));
    return;
  }
  Promise.resolve({ ok: true, value: '' }).then((v) => win.__qrResolve(m.id, v));
};

(async () => {
  const k = await win.__qrInvoke('exploreKinds', { source: SRC });
  eq('分类数量', k.kinds.length, 6);
  eq('首个分类名', k.kinds[0] && k.kinds[0].title, '全部小说');
  eq('分类 URL 补全', k.kinds[0] && k.kinds[0].url, 'https://m.powenxue15.com/sort/1/{{page}}/');

  const e = await win.__qrInvoke('explore', { source: SRC, kindUrl: 'https://m.powenxue15.com/sort/dushi/1/', page: 1 });
  eq('出书数量', (e.books || []).length, 3);
  eq('书名 1', e.books[0] && e.books[0].name, ITEMS[0].name);
  eq('书名 2', e.books[1] && e.books[1].name, ITEMS[1].name);
  eq('书名 3（带广告后缀的那个）', e.books[2] && e.books[2].name, ITEMS[2].name);
  eq('作者', e.books[0] && e.books[0].author, ITEMS[0].author);
  eq('书籍 URL', e.books[0] && e.books[0].bookUrl, 'https://m.powenxue15.com/info/122448.html');
  eq('封面取 data-original（不是占位图）', e.books[0] && e.books[0].coverUrl,
     'https://img.powenxue15.com/image/122/122448/122448s.jpg');
  eq('封面不是 nocover 占位图', /nocover/.test((e.books[0] || {}).coverUrl || ''), false);
  eq('简介', e.books[0] && e.books[0].intro, ITEMS[0].intro);
  eq('状态', e.books[0] && e.books[0].kind, ITEMS[0].state);
  eq('字数', e.books[0] && e.books[0].wordCount, ITEMS[0].words);

  console.log(`肉文屋新规则验证：${pass} 通过 / ${fail} 失败`);
  if (fails.length) { fails.forEach((f) => console.log('  ✗ ' + f)); process.exit(1); }
  fs.writeFileSync('/tmp/rouwenwu-src.json', JSON.stringify(SRC, null, 2), 'utf8');
  console.log('已写出测试源 /tmp/rouwenwu-src.json');
})().catch((e) => { console.error('崩溃:', e); process.exit(1); });
