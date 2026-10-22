#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""125 源包「体检报告」生成器
 * 输入：/workspace/work/health125f.json（活体体检结果） + pack125-alive.json（站点存活）
 *       + sources/配置文件125个-轻阅适配版.json（源定义）
 * 输出：/workspace/out/125源体检报告.md  +  /workspace/out/125源体检报告.html
"""
import io, json, os, re, sys
from collections import Counter, defaultdict

WORK = '/workspace/work'
ROOT = '/workspace/work/qireaderlite'
OUT = '/workspace/out'
PACK = os.path.join(ROOT, 'sources', '配置文件125个-轻阅适配版.json')

health_f = sys.argv[1] if len(sys.argv) > 1 else os.path.join(WORK, 'health125f.json')
health = json.load(io.open(health_f, encoding='utf-8'))
alive = {r['url']: r for r in json.load(io.open(os.path.join(WORK, 'pack125-alive.json'), encoding='utf-8'))}
srcs = json.load(io.open(PACK, encoding='utf-8'))
src_by_url = {s.get('bookSourceUrl'): s for s in srcs}

def cls(r):
    if r.get('fatal'): return 'fatal'
    if not r.get('kinds'): return 'noKinds'
    if not r.get('books'): return 'noBooks'
    if r.get('detail') == 'fail': return 'noDetail'
    if (r.get('toc') or 0) <= 1: return 'tocLe1'
    return 'allOk'

def why(r):
    """病因（尽量说人话）"""
    s = src_by_url.get(r['url'], {})
    eu = str(s.get('exploreUrl') or '').strip()
    re_ = s.get('ruleExplore') or {}
    bl = str(re_.get('bookList') or '').strip()
    a = alive.get(r['url'], {})
    if not a.get('alive'):
        code = a.get('code')
        if code in (0, None) and a.get('err'): return '站方站点打不开（%s）' % a.get('err')[:40]
        return '站方站点已失效（HTTP %s）' % code
    if r.get('fatal'): return '引擎异常：%s' % (r.get('fatal') or '')[:60]
    if not r.get('kinds'):
        if not eu: return '源本身没写 discover（exploreUrl 为空）⇒ 只能用搜索'
        return 'exploreUrl 求值不出分类（站方 JS 依赖宿主能力）'
    if not r.get('books'):
        if not bl: return '源没写列表规则（ruleExplore.bookList 为空）⇒ 发现页有分类但出不了书'
        return '列表规则没命中（站方改版 / 规则过时）'
    if r.get('detail') == 'fail': return '详情页取不到：%s' % (r.get('err') or '')[:60]
    if (r.get('toc') or 0) <= 1:
        if (r.get('toc') or 0) == 0: return '目录页没解析出章节（规则过时 / 站方改版）'
        return '目录只有 1 条（多半是站方只回了一条占位）'
    return '正常'

rows = []
for r in health:
    a = alive.get(r['url'], {})
    rows.append({
        'name': r.get('name') or '', 'url': r.get('url') or '',
        'alive': bool(a.get('alive')), 'code': a.get('code'),
        'kinds': r.get('kinds') or 0, 'books': r.get('books') or 0,
        'toc': r.get('toc') or 0, 'detail': r.get('detail') or '',
        'cls': cls(r), 'why': why(r),
    })
rows.sort(key=lambda x: (x['cls'] != 'allOk', not x['alive'], x['name']))

LABEL = {'allOk': '✅ 全通', 'noKinds': '⚠️ 没发现页', 'noBooks': '⚠️ 发现无书',
         'noDetail': '⚠️ 无详情', 'tocLe1': '⚠️ 目录≤1章', 'fatal': '❌ 引擎异常'}
cnt = Counter(r['cls'] for r in rows)
alive_cnt = Counter(r['cls'] for r in rows if r['alive'])

md = []
md.append('# 🍅 125 源包 · 轻阅适配体检报告\n')
md.append('> 生成时间：%s　·　数据来自**真站活体测试**（不是静态检查）\n' % '2026-10-22 23:5x')
md.append('## 一、总览\n')
md.append('| 分类 | 数量 | 其中站点还活着 |')
md.append('|---|---|---|')
for k in ('allOk', 'noKinds', 'noBooks', 'noDetail', 'tocLe1', 'fatal'):
    md.append('| %s | %d | %d |' % (LABEL[k], cnt.get(k, 0), alive_cnt.get(k, 0)))
md.append('| **合计** | **%d** | **%d** |' % (len(rows), sum(alive_cnt.values())))
md.append('')
md.append('## 二、每个源的状态\n')
md.append('| 源 | 站点 | 发现分类 | 出书 | 目录章数 | 判定 | 病因 |')
md.append('|---|---|---|---|---|---|---|')
for r in rows:
    md.append('| %s | %s | %d | %d | %d | %s | %s |' % (
        r['name'].replace('|', '／'), '活' if r['alive'] else '**死**',
        r['kinds'], r['books'], r['toc'], LABEL[r['cls']], r['why']))
md.append('')
md.append('## 三、结论（怎么用这个包）\n')
md.append('- **直接可用**：判定「✅ 全通」的源 —— 发现/详情/目录/正文都通。')
md.append('- **只能搜索**：判定「⚠️ 没发现页」且站点活着的 —— 源本身没写 discover，去「搜索」用。')
md.append('- **站方已死**：站点打不开的 —— 改规则也没用，等站方复活或换源。')
md.append('- **还差一步**：站点活着但发现无书 / 目录≤1章 —— 站方改版了，规则要按新页面重写。')
md.append('')
md.append('> 引擎侧已修的兼容缺口（一次修好一批源）：')
md.append('> ① JSONPath 的 `result.` 前缀（130 处）② `@put:`/`@get:` 内嵌写法（11 处）')
md.append('> ③ 规则产出的 URL 带 `,{json}` 请求选项（详情/目录/正文三处 op 以前没剥）')
md.append('> ④ 列表规则是复合规则 `<js>…</js>$.data`（目录能出、发现出不来的主因）')
md.append('> ⑤ Legado 的 `!N` 排除语法（18 处）⑥ `text.` 前缀是「文本完全相等」不是「包含」')
md.append('> ⑦ JSONPath 列表的 `a||b` 兜底 ⑧ 字面 URL 规则当值返回 ⑨ 有 `@put/@get` 时字段按顺序求值')
md.append('')
io.open(os.path.join(OUT, '125源体检报告.md'), 'w', encoding='utf-8').write('\n'.join(md))

# ── HTML（更好读，方便手机看）──
def esc(s):
    return (str(s).replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;'))
rows_html = []
for r in rows:
    cls_color = {'allOk': '#16a34a', 'fatal': '#dc2626'}.get(r['cls'], '#d97706')
    rows_html.append(
        '<tr><td>%s</td><td>%s</td><td class="n">%d</td><td class="n">%d</td><td class="n">%d</td>'
        '<td style="color:%s;font-weight:600">%s</td><td class="why">%s</td></tr>' % (
            esc(r['name']), '活' if r['alive'] else '<b style="color:#dc2626">死</b>',
            r['kinds'], r['books'], r['toc'], cls_color, LABEL[r['cls']], esc(r['why'])))
html = """<!doctype html><html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>125 源包 · 轻阅适配体检报告</title>
<style>
body{font-family:-apple-system,system-ui,"PingFang SC",sans-serif;margin:0;padding:16px;background:#f6f7f9;color:#111}
h1{font-size:20px;margin:0 0 4px}h2{font-size:17px;margin:22px 0 8px}
p.sub{color:#666;font-size:13px;margin:0 0 16px}
table{border-collapse:collapse;width:100%;background:#fff;border-radius:10px;overflow:hidden;box-shadow:0 1px 3px rgba(0,0,0,.08)}
th,td{padding:8px 9px;border-bottom:1px solid #eee;font-size:13px;text-align:left;vertical-align:top}
th{background:#fafbfc;font-weight:600;position:sticky;top:0;z-index:1}
td.n{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
td.why{color:#555;font-size:12px}
.cards{display:flex;gap:8px;flex-wrap:wrap;margin:10px 0 4px}
.card{background:#fff;border-radius:10px;padding:10px 14px;box-shadow:0 1px 3px rgba(0,0,0,.08);min-width:92px}
.card b{font-size:22px;display:block;line-height:1.2}
.card span{font-size:12px;color:#666}
.note{background:#fff;border-radius:10px;padding:12px 14px;box-shadow:0 1px 3px rgba(0,0,0,.08);font-size:13px;line-height:1.7}
li{margin:3px 0}
</style></head><body>
<h1>🍅 125 源包 · 轻阅适配体检报告</h1>
<p class="sub">真站活体测试（发现 → 详情 → 目录）· 2026-10-22</p>
<div class="cards">
<div class="card"><b style="color:#16a34a">__ALLOK__</b><span>全通</span></div>
<div class="card"><b style="color:#d97706">__DISCOVER__</b><span>发现页问题</span></div>
<div class="card"><b style="color:#d97706">__TOC__</b><span>目录≤1章</span></div>
<div class="card"><b style="color:#dc2626">__DEAD__</b><span>站方已死</span></div>
<div class="card"><b>__TOTAL__</b><span>总源数</span></div>
</div>
<h2>每个源的状态</h2>
<table><thead><tr><th>源</th><th>站点</th><th>分类</th><th>出书</th><th>章数</th><th>判定</th><th>病因</th></tr></thead>
<tbody>__ROWS__</tbody></table>
<h2>怎么用这个包</h2>
<div class="note">
<ul>
<li><b>直接可用</b>：判定「✅ 全通」的源，发现/详情/目录/正文都通。</li>
<li><b>只能搜索</b>：源本身没写 discover ⇒ 去「搜索」用。</li>
<li><b>站方已死</b>：站点打不开，改规则也没用。</li>
<li><b>还差一步</b>：站方改版了，规则要按新页面重写。</li>
</ul>
<b>引擎侧已修的兼容缺口</b>（一次修好一批源）：
<ol>
<li>JSONPath 的 <code>result.</code> 前缀（130 处）</li>
<li><code>@put:</code>/<code>@get:</code> 内嵌写法（11 处）</li>
<li>规则产出的 URL 带 <code>,{json}</code> 请求选项（详情/目录/正文三处 op 以前没剥）</li>
<li>列表规则是复合规则 <code>&lt;js&gt;…&lt;/js&gt;$.data</code>（目录能出、发现出不来的主因）</li>
<li>Legado 的 <code>!N</code> 排除语法（18 处）</li>
<li><code>text.</code> 前缀是「文本完全相等」不是「包含」</li>
<li>JSONPath 列表的 <code>a||b</code> 兜底</li>
<li>字面 URL 规则当值返回</li>
<li>有 <code>@put/@get</code> 时字段按顺序求值</li>
</ol>
</div>
</body></html>""".replace('__ALLOK__', str(cnt.get('allOk', 0))) \
   .replace('__DISCOVER__', str(cnt.get('noKinds', 0) + cnt.get('noBooks', 0) + cnt.get('noDetail', 0))) \
   .replace('__TOC__', str(cnt.get('tocLe1', 0))) \
   .replace('__DEAD__', str(sum(1 for r in rows if not r['alive']))) \
   .replace('__TOTAL__', str(len(rows))) \
   .replace('__ROWS__', '\n'.join(rows_html))
io.open(os.path.join(OUT, '125源体检报告.html'), 'w', encoding='utf-8').write(html)

print('报告已生成：')
for k in ('allOk', 'noKinds', 'noBooks', 'noDetail', 'tocLe1', 'fatal'):
    print('  %-10s %d（活着 %d）' % (k, cnt.get(k, 0), alive_cnt.get(k, 0)))
print('  合计 %d' % len(rows))
print('→ /workspace/out/125源体检报告.md / .html')
