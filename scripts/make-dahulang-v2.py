#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
🍅大灰狼聚合源 → **轻阅适配版 v2**（每章 URL 一次算完）

背景
----
大灰狼的 `ruleToc.chapterUrl` 是**每章一次** `<js>`：

    <js>
    let tab = result.tab; … let qtcontent = {…};
    qtcontent = java.base64Encode(JSON.stringify(qtcontent));
    if (sources == '卷') { content_url = item_id }
    else { content_url = `data:;base64,${qtcontent},{"type":"qingtian3"}`; }
    </js>

目录有 2000+ 章 → 引擎要跑 2000+ 次 JS 求值 + 2000+ 次 base64。
真机（WKWebView）上这一步非常慢 → 表现是「目录一直不出来 / 像卡住」。

栖阅《书源制作文档》§5.5 明说：
> 绝对不要把 `@js:` 写进 `chapterUrl`……把 URL 计算搬到 `chapterList` 阶段一次算完。

v2 干什么
--------
1. `ruleToc.chapterList` 的 JS 末尾**追加一段**：把目录里每一章的正文 URL
   **在列表阶段一次算完**，塞进章节对象的 `qr_url` 字段；
2. `ruleToc.chapterUrl` 改成 `$.qr_url`（每章 **0 次 JS**）。

⚠️ URL 的算法**逐字节沿用原版 chapterUrl 的 JS**（不重新实现），
   只把它包进一个函数、把 `result` 绑到当前章节 —— 避免两份逻辑跑偏。

用法
----
    python3 scripts/make-dahulang-v2.py <原版.json> <输出v2.json>
"""
import io
import json
import re
import sys

# 追加到 chapterList JS 末尾的「预计算」代码
PRECOMPUTE = """
// ── 轻阅适配 v2：把每章的正文 URL 在列表阶段一次算完（原来每章一次 JS）──
try {{
    var __qr_url_fn = function(__qr_it) {{
        var result = __qr_it;      // 站方代码只认 result
        var content_url = '';      // 站方最后是**裸赋值** content_url = …
{inner}
        return content_url;
    }};
    var __qr_cap = JSON.parse(data);
    if (__qr_cap && Array.isArray(__qr_cap.data)) {{
        __qr_cap.data.forEach(function(__qr_it) {{
            try {{ __qr_it.qr_url = __qr_url_fn(__qr_it) || ''; }}
            catch (e) {{ __qr_it.qr_url = ''; }}
        }});
        data = JSON.stringify(__qr_cap);
    }}
}} catch (e) {{
    java.log('预计算章节URL失败:' + e);
}}
data;
"""


def inner_js(rule: str) -> str:
    """取 <js>…</js> 里面的代码（去掉标签）。"""
    m = re.search(r"<js>(.*)</js>", rule, re.S | re.I)
    if not m:
        raise SystemExit("规则里没有 <js> 块")
    return m.group(1)


def make_v2(src: dict) -> dict:
    toc = src.get("ruleToc") or {}
    cl = toc.get("chapterList") or ""
    cu = toc.get("chapterUrl") or ""

    # 1) chapterList 的 JS：把最后那句 `data;` 换成「预计算 + data;」
    m = re.search(r"<js>(.*)</js>(.*)$", cl, re.S)
    if not m:
        raise SystemExit("chapterList 不是 <js>…</js> 形状")
    js_body, tail = m.group(1), m.group(2)

    # 找到 JS 主体（最后那句完成值 `data;`）——把它切掉
    body = js_body
    end = None
    for mm in re.finditer(r"(^|\n)\s*data\s*;\s*(\n|$)", js_body):
        end = mm
    if end is None:
        raise SystemExit("chapterList 的 JS 里找不到结尾的 `data;`")
    head = js_body[: end.start()]
    indent = ""
    im = re.search(r"\n([ \t]+)data\s*;", js_body)
    if im:
        indent = im.group(1)

    # 2) chapterUrl 的 JS：原样搬进函数（只补 result 绑定 + content_url 声明）
    cu_inner = inner_js(cu)
    # 站方最后是裸赋值 `content_url = …` → 函数里必须先声明，否则读到的是全局
    cu_inner_patched = re.sub(r"(^|\n)(\s*)content_url\s*=", r"\1\2content_url =", cu_inner)

    pre = PRECOMPUTE.format(inner=cu_inner_patched)
    # 按原缩进缩进整块
    pre = "\n".join((indent + ln) if ln.strip() else ln for ln in pre.split("\n"))

    new_js = head + pre
    new_cl = "<js>" + new_js + "</js>" + tail

    out = dict(src)
    new_toc = dict(toc)
    new_toc["chapterList"] = new_cl
    new_toc["chapterUrl"] = "$.qr_url"
    out["ruleToc"] = new_toc
    out["bookSourceComment"] = (
        str(src.get("bookSourceComment") or "")
        + "\n【轻阅适配v2】每章正文URL在目录阶段一次算完（chapterUrl 改为 $.qr_url），"
          "真机目录不再卡。原始规则见 v1。"
    ).strip()
    return out


def main() -> None:
    if len(sys.argv) != 3:
        print(__doc__)
        raise SystemExit(2)
    src_path, out_path = sys.argv[1], sys.argv[2]
    data = json.load(io.open(src_path, encoding="utf-8"))
    if isinstance(data, list):
        out = [make_v2(s) for s in data]
    else:
        out = make_v2(data)
    with io.open(out_path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    print("✓ 生成:", out_path)


if __name__ == "__main__":
    main()
