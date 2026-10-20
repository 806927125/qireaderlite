#!/usr/bin/env python3
"""从门禁输出里抠出「通过数 / 失败数」。

为什么要单独一个文件：门禁的汇总行格式有好几种，
    通过 48 / 失败 0
    37 通过 / 0 失败
    通过 20 失败 0
    规则引擎: 39 通过 / 0 失败
    端到端全链路: 37 通过 / 0 失败
以前每个文件格式不一样 → 脚本里一堆正则各不相同 → 漏一个就当没跑过。

用法：node test/x.test.js | python3 test/parse-summary.py
输出：`<通过数> <失败数>`（抠不到就输出空）
"""
import re
import sys

# 「通过 N」或「N 通过」+ 「失败 M」或「M 失败」，
# 中间允许最多 6 个非数字字符（: / 空格）
PAT = re.compile(
    r"(?:通过\s*([0-9]+)|([0-9]+)\s*通过)"
    r"\D{0,6}?"
    r"(?:失败\s*([0-9]+)|([0-9]+)\s*失败)"
)


def main() -> int:
    txt = sys.stdin.read()
    best = None
    for line in txt.splitlines():
        m = PAT.search(line)
        if m:
            g = m.groups()
            p = g[0] or g[1]
            f = g[2] or g[3]
            best = (int(p), int(f))
    if best:
        print(best[0], best[1])
    return 0


if __name__ == "__main__":
    sys.exit(main())
