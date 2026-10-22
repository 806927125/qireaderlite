#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# 把 125 源包的体检结论写进每个源的 bookSourceComment（用户在 App 里就能看到）
# 用法：python3 test/pack125-annotate.py [health125g.json]
# 输出：sources/配置文件125个-轻阅适配版-体检标注.json

import io, json, os, sys

ROOT = '/workspace/work/qireaderlite'
PACK = os.path.join(ROOT, 'sources', '配置文件125个-轻阅适配版.json')
OUT = os.path.join(ROOT, 'sources', '配置文件125个-轻阅适配版-体检标注.json')
health_f = sys.argv[1] if len(sys.argv) > 1 else '/workspace/work/health125g.json'

health = {r['url']: r for r in json.load(io.open(health_f, encoding='utf-8'))}
alive = {r['url']: r for r in json.load(io.open('/workspace/work/pack125-alive.json', encoding='utf-8'))}
srcs = json.load(io.open(PACK, encoding='utf-8'))

STAMP = '【轻阅体检 2026-10-22】'


def verdict(u):
    r = health.get(u)
    if not r:
        return '未体检', '未体检'
    a = alive.get(u, {})
    k, b, t = r.get('kinds') or 0, r.get('books') or 0, r.get('toc') or 0
    if not a.get('alive'):
        code = a.get('code')
        return '⚫ 站方已失效', '站点打不开（HTTP %s）⇒ 改规则也没用，等站方恢复或换源' % (code if code else '超时')
    if not k:
        return '⚪ 只能用搜索', '这个源本身没写发现页（exploreUrl 为空）⇒ 请用「搜索」'
    if not b:
        return '🟡 发现页出不了书', '有分类但列表规则没命中（站方改版）⇒ 搜索一般还能用'
    if r.get('detail') == 'fail':
        return '🟡 详情页取不到', '列表能出，但详情页规则没命中（站方改版）'
    if t <= 1:
        return '🟡 目录出不来', '发现/详情正常，但目录规则没命中（站方改版）⇒ 目录只有 %d 条' % t
    return '✅ 全通', '发现 %d 个分类 / 列表 %d 本 / 目录 %d 章，都正常' % (k, b, t)


n = 0
for s in srcs:
    u = s.get('bookSourceUrl') or ''
    v, note = verdict(u)
    old = str(s.get('bookSourceComment') or '').strip()
    parts = [x for x in old.split('\n') if STAMP not in x and x.strip()]
    parts.append('%s%s：%s' % (STAMP, v, note))
    s['bookSourceComment'] = '\n'.join(parts).strip()
    n += 1

io.open(OUT, 'w', encoding='utf-8').write(json.dumps(srcs, ensure_ascii=False, indent=2))
print('已标注 %d 个源 → %s' % (n, OUT))
print('（原文件没动：%s）' % PACK)
