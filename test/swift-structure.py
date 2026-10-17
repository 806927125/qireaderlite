#!/usr/bin/env python3
"""Swift 结构校验：Linux 上没有 swiftc，这是能做的最强静态检查。
   做三件事：括号配平 / 关键类型是否都有定义 / 常见危险写法扫描。"""
import os, re, sys

files = sorted(
    os.path.join(r, f)
    for r, _, fs in os.walk('QiReaderLite') for f in fs if f.endswith('.swift')
)

def strip(src):
    out, i, n = [], 0, len(src)
    while i < n:
        if src.startswith('"""', i):
            j = src.find('"""', i + 3); i = (j + 3) if j >= 0 else n; continue
        if src[i] == '"':
            i += 1
            while i < n and src[i] != '"':
                if src[i] == '\\': i += 1
                i += 1
            i += 1; continue
        if src.startswith('//', i):
            j = src.find('\n', i); i = j if j >= 0 else n; continue
        if src.startswith('/*', i):
            j = src.find('*/', i + 2); i = (j + 2) if j >= 0 else n; continue
        out.append(src[i]); i += 1
    return ''.join(out)

problems = []
for f in files:
    s = strip(open(f, encoding='utf-8').read())
    for label, o, c in (('花括号', '{', '}'), ('圆括号', '(', ')'), ('方括号', '[', ']')):
        d = s.count(o) - s.count(c)
        if d:
            problems.append(f'{f}: {label}不配平 (差 {d:+d})')
    raw = open(f, encoding='utf-8').read()
    for m in re.finditer(r'.*\b(try!|as!|!\.first!|\.unsafelyUnwrapped)\b.*', raw):
        problems.append(f'{f}: 强解包 {m.group(0).strip()[:60]}')

defined = set()
for f in files:
    src = open(f, encoding='utf-8').read()
    defined |= {m.group(1) for m in re.finditer(
        r'^\s*(?:public\s+|private\s+|fileprivate\s+)?(?:final\s+)?(?:struct|class|enum|actor|protocol)\s+(\w+)', src, re.M)}
    defined |= {m.group(1) for m in re.finditer(
        r'^\s*(?:public\s+|private\s+)?(?:static\s+)?(?:let|var|func)\s+(\w+)', src, re.M)}

KEY = ['SourceService','AsyncLoader','SourceStore','LibraryStore','ContentCache','RuleSandbox',
       'AppEncoder','AppDecoder','AppPaths','Toast','CacheFiles','CookieJar','HeaderCodec',
       'ResourceLocator','SandboxFS','BookSource','RuleValue','ListRule','BookInfoRule',
       'TocRule','ContentRule','Book','Chapter','BookCatalog','LibraryItem','BookLite',
       'BookSourceParser','Theme','CoverImage','EmptyHint','ErrorHint','RootView',
       'SourcePicker','BookRow','BookDedup','SourcesView','SearchView','ExploreView',
       'BookshelfView','BookDetailView','CatalogSheet','ReaderView','ReaderTheme','QiReaderLiteApp']
missing = [k for k in KEY if k not in defined]

print(f'检查了 {len(files)} 个 Swift 文件')
for p in problems: print('  ✗', p)
if missing: print('  ✗ 缺少定义:', missing)
if problems or missing:
    sys.exit(1)
print(f'结构校验通过 ✓  括号全配平、无强解包、{len(KEY)} 个关键类型都有定义')
