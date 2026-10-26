/**
 * **Swift DTO 容错解码门禁**（纯静态检查，不跑 Swift）
 *
 * 背景（2026-10-23 真机）：装完 build214 进「创世中文网」发现页 ⇒
 *   「解析 KindsDTO 失败 —— 出错字段：kinds.[0] / 缺字段 group」
 *   ⇒ **整个发现页报错**，一个分类都点不了。
 *
 * ⚠️⚠️ 根因是 Swift `Codable` 的一个经典坑：
 *   **`var group: String = ""` 这样的「属性默认值」只对【构造】生效，
 *   对【解码】不生效** —— 合成 `init(from:)` 遇到 JSON 里**缺这个键**
 *   ⇒ 直接抛 `keyNotFound` ⇒ 整个 op 的结果全废。
 *   ⇒ 而老式静态分类（`标题::URL`）的 kind **本来就没有 group 字段**。
 *
 * ⇒ 修法：所有响应 DTO 都写**容错解码**（`decodeIfPresent ?? 默认值`），
 *   跟 `BookDTO` 早先的做法一样。
 *
 * ⚠️ 这类 bug 沙盒门禁抓不到（沙盒直接调 `__qrInvoke`，**不经过 Swift 解码**）
 *   ⇒ 只能静态比对（跟 `swift-bookdto.test.js` 同一个路子）。
 */
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '..', 'QiReaderLite');

let pass = 0, fail = 0;
function ok(c, label, extra) {
  if (c) { pass++; console.log(`  ✓ ${label}`); }
  else { fail++; console.log(`  ✗ ${label}${extra ? '  → ' + extra : ''}`); }
}

const svc = fs.readFileSync(path.join(ROOT, 'Core/SourceService.swift'), 'utf8');

/** 取某个 struct 的源码块 */
function structBody(name) {
  const re = new RegExp(`struct ${name}: Codable[^{]*\\{([\\s\\S]*?)\\n    \\}`);
  const m = re.exec(svc);
  return m ? m[1] : '';
}

console.log('\n── 1. 这几个 DTO 必须有容错解码（缺一个键就整页炸）──');
for (const name of ['KindDTO', 'FilterDTO', 'ChapterDTO', 'ContentDTO']) {
  const body = structBody(name);
  ok(!!body, `能定位到 ${name}`);
  ok(/init\(from decoder: Decoder\) throws/.test(body),
     `${name} 有自定义 init(from:)`);
  ok(/decodeIfPresent/.test(body),
     `${name} 用的是 decodeIfPresent（不会因缺键抛 keyNotFound）`);
}

console.log('\n── 2. 不能再出现「只有属性默认值、没有容错解码」的响应 DTO ──');
// 这些是引擎一定会给的字段，但为了保险也要求容错
for (const name of ['BookDTO', 'BookListDTO', 'KindsDTO', 'TocDTO', 'BookInfoDTO']) {
  const body = structBody(name);
  if (!body) continue;
  const hasNonOpt = /var \w+: (String|Int|Bool) = /.test(body);
  const tolerant = /decodeIfPresent/.test(body);
  ok(!hasNonOpt || tolerant,
     `${name} 的非可选字段都有容错解码`,
     hasNonOpt ? '有非可选字段但没有 decodeIfPresent' : '');
}

console.log('\n── 3. 关键：group 字段必须是「可缺省」而不是「必填」──');
{
  const body = structBody('KindDTO');
  ok(/var group: String = ""/.test(body), 'KindDTO 声明了 group');
  ok(/case title, url, style, group/.test(body), 'KindDTO 的 CodingKey 含 group');
  ok(/group = g\(\.group\)/.test(body), 'group 是用 decodeIfPresent 兜底取的');
}

console.log('\n── 4. 目录翻页：页数上限要够（站方一次给全量页数组时）──');
ok(/maxPages": 20/.test(svc),
   'Swift 侧 toc op 传 maxPages=20（原来 5 页 ⇒ 大书只出 250 章）',
   (/\["tocUrl"[^\]]*\]/.exec(svc) || [''])[0]);
ok(/Math\.max\(1, p\.maxPages \|\| 10\)/.test(
     fs.readFileSync(path.join(ROOT, 'Resources/engine/engine.js'), 'utf8')),
   '引擎默认 maxPages=10（原来 3）');

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}`);
process.exit(fail ? 1 : 0);
