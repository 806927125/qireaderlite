#!/usr/bin/env python3
"""
⭐⭐⭐ 用 Git Trees API 一次提交多个文件（git push 走 GnuTLS 老失败时的兜底通道）

用法：python3 push-via-api.py <repo> <file1> [file2 ...]
      file 路径相对仓库根；要带「+前缀」表示新增文件
"""
import base64, json, os, subprocess, sys, urllib.request

# ⭐⭐⭐⭐⭐ **PAT 只从环境变量读，绝不硬编码进仓库**
#   ⇒ GitHub 的 secret scanning 会拦含 PAT 的提交（422 "Secret detected in content"）⭐⭐⭐
#   ⇒ 而且硬编码进仓库 = **凭据泄露**（谁 clone 谁就能用你的 token）⭐⭐⭐
TOK = os.environ.get('GITHUB_PAT') or os.environ.get('GH_PAT') or ''
if not TOK:
    print('⚠️ 没给 PAT ⇒ 用环境变量 GITHUB_PAT 传（或 GH_PAT）')
    sys.exit(1)
REPO = sys.argv[1]
FILES = sys.argv[2:]
BASE = f'https://api.github.com/repos/806927125/{REPO}'
MSG = os.environ.get('PUSH_MSG', '⭐ 提交改动')


def api(url, method='GET', data=None, raw=False):
    req = urllib.request.Request(url, method=method, data=data)
    req.add_header('Authorization', 'Bearer ' + TOK)
    req.add_header('Accept', 'application/vnd.github+json')
    req.add_header('User-Agent', 'mavis')
    if data is not None:
        req.add_header('Content-Type', 'application/json')
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            body = r.read()
    except urllib.error.HTTPError as e:
        raise RuntimeError(f'{method} {url} -> {e.code}: {e.read().decode()[:600]}')
    return body if raw else json.loads(body)


def main():
    head = api(BASE + '/git/ref/heads/main')['object']['sha']
    base_tree = api(BASE + '/git/commits/' + head)['tree']['sha']
    print('远端 HEAD:', head[:8], ' base tree:', base_tree[:8])

    entries = []
    for f in FILES:
        path = f[1:] if f.startswith('+') else f
        try:
            content = open(path, 'rb').read()
        except FileNotFoundError:
            print('  ⚠️ 跳过（本地没有）:', path)
            continue
        blob = api(BASE + '/git/blobs', 'POST',
                   json.dumps({'content': base64.b64encode(content).decode(),
                               'encoding': 'base64'}).encode())
        mode = '100644'
        if path.endswith('.sh'):
            mode = '100755'
        entries.append({'path': path, 'mode': mode, 'type': 'blob', 'sha': blob['sha']})
        print('  ✅ blob', path, blob['sha'][:8])

    tree = api(BASE + '/git/trees', 'POST',
               json.dumps({'base_tree': base_tree, 'tree': entries}).encode())
    print('新 tree:', tree['sha'][:8], '（', len(entries), '个文件 ）')

    commit = api(BASE + '/git/commits', 'POST',
                 json.dumps({'message': MSG, 'tree': tree['sha'],
                             'parents': [head]}).encode())
    print('新 commit:', commit['sha'][:8])

    api(BASE + '/git/refs/heads/main', 'PATCH',
        json.dumps({'sha': commit['sha'], 'force': False}).encode())
    print('✅ 已更新 main →', commit['sha'][:8])


main()
