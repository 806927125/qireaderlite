// 变异对照：⭐⭐⭐⭐⭐ **证明 `engine-apple-api.test.js` 的每条断言都可证伪**（2026-11-19）
//
// 跑法：node test/engine-apple-api.mutation.test.js
//
// ⭐⭐⭐ **为什么必须有这个**（2026-11-19 实证）：
//   上一版门禁**断言了三条错误结论**（禁 `ccPKCS7Padding` / 断言 11 个参数 / 要求不包 compression_* 类型）
//   ⇒ 门禁一直绿，CI 一直红，**两个都"对"不了** ⭐⭐⭐
//   ⇒ 教训：**门禁绿 ≠ 代码对** ⇒ 必须用变异证明「把实现改坏 ⇒ 门禁会红」⭐⭐⭐
//   ⇒ 也防止「断言写得太宽松 ⇒ 恒真 ⇒ 改坏实现也绿」⭐⭐⭐
//
// ⚠️ **纪律**：变异前必须 `cp` 备份；**不许用 `git checkout --` 恢复**
//   （那恢复的是已提交版本 ⇒ 会把未提交的改动冲掉 ⇒ 真代码没了）

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.join(__dirname, '..');
const TARGET = path.join(ROOT, 'LegadoEngine', 'Sources', 'LegadoEngine', 'JS', 'JSNatives.swift');
const GATE = path.join(__dirname, 'engine-apple-api.test.js');
const BACKUP = TARGET + '.mutation-backup';

const original = fs.readFileSync(TARGET, 'utf8');
fs.writeFileSync(BACKUP, original, 'utf8');

/** 跑门禁 ⇒ 返回 exit code（0=绿） */
function runGate() {
  try {
    execFileSync('node', [GATE], { cwd: ROOT, stdio: 'pipe' });
    return 0;
  } catch (e) {
    return e.status === undefined ? -1 : e.status;
  }
}

let failed = 0, passed = 0;
function check(name, cond, extra) {
  if (cond) { passed++; console.log('  ✓', name); }
  else { failed++; console.log('  ✗', name, extra === undefined ? '' : ('→ ' + extra)); }
}

// ── 前置：未变异时门禁必须是绿的 ──
check('基准：未变异时门禁绿', runGate() === 0, '基准就不是绿的 ⇒ 变异对照无意义');

// ── 每条变异：改坏实现 ⇒ 门禁必须红 ──
const MUTATIONS = [
  {
    name: 'compression_stream 用零参 init（C struct 没有零参 init）',
    from: 'var stream = compression_stream(dst_ptr: nil, dst_size: 0, src_ptr: nil, src_size: 0, state: nil)',
    to: 'var stream = compression_stream()',
  },
  {
    name: 'ZLIB 写成 0（静默用错算法）',
    from: 'compression_algorithm(rawValue: UInt32(0x205))',
    to: 'compression_algorithm(rawValue: UInt32(0))',
  },
  {
    name: 'compression_stream_init 直接传裸 UInt32（不包 compression_* 类型）',
    from: 'guard compression_stream_init(&stream, op, alg) == statusOK else { return Data() }',
    to: 'guard compression_stream_init(&stream, UInt32(0), UInt32(0x205)) == statusOK else { return Data() }',
  },
  {
    name: 'rawValue 用 Int32（真值是 UInt32）',
    from: 'compression_stream_operation(rawValue: UInt32(encode ? 0 : 1))',
    to: 'compression_stream_operation(rawValue: Int32(encode ? 0 : 1))',
  },
  {
    // ⭐ 锚点必须打在【代码行】上 ⇒ 直接打三元表达式 ⇒ 不会误命中注释里的名字 ⭐⭐⭐
    name: 'padding 用不存在的常量名 kCCPaddingPKCS7',
    from: 'usePadding ? ccPKCS7Padding : ccNoPadding',
    to: 'usePadding ? kCCPaddingPKCS7 : ccNoPadding',
  },
  {
    name: 'padding 丢掉 ccNoPadding（半个三元）',
    from: 'usePadding ? ccPKCS7Padding : ccNoPadding',
    to: 'usePadding ? ccPKCS7Padding : CCPadding(0)',
  },
  {
    name: 'CCCryptorCreateWithMode 少传一个参数（11 个）',
    from: 'nil, 0, 0, ccOptions, &cryptor)',
    to: 'nil, 0, ccOptions, &cryptor)',
  },
  {
    name: 'withUnsafeBytes 闭包去掉显式标注（重载歧义）',
    from: 'iv.withUnsafeBytes { (ivPtr: UnsafeRawBufferPointer) in',
    to: 'iv.withUnsafeBytes { ivPtr in',
  },
];

/** ⭐⭐⭐ **剥注释**（与门禁同一条规则 ⇒ 单一真相）
 *   ⇒ 变异锚点**必须命中【代码】**，不能只命中注释
 *   ⇒ 否则「变异只改了注释」⇒ 门禁当然还是绿 ⇒ 变异对照就是假的 ⭐⭐⭐ */
function stripComments(code) {
  return code.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/\/\/[^\n]*/g, ' ');
}

for (const m of MUTATIONS) {
  if (!original.includes(m.from)) {
    check(`变异「${m.name}」：锚点命中`, false, `锚点没命中：${m.from.slice(0, 50)}`);
    continue;
  }
  const mutated = original.replace(m.from, m.to);
  // ⭐⭐⭐ **变异必须真的改到了代码**（剥注释后有差异）⇒ 否则这条变异是假的 ⭐⭐⭐
  if (stripComments(mutated) === stripComments(original)) {
    check(`变异「${m.name}」：锚点命中的是代码而不是注释`, false,
          '剥注释后无差异 ⇒ 锚点只命中了注释 ⇒ 变异无效');
    continue;
  }
  fs.writeFileSync(TARGET, mutated, 'utf8');
  const rc = runGate();
  check(`变异「${m.name}」⇒ 门禁红`, rc !== 0, `门禁居然是绿的（exit=${rc}）⇒ 这条断言是摆设`);
  fs.writeFileSync(TARGET, original, 'utf8');
}

// ── 后置：恢复后门禁必须仍然是绿的（证明变异没留下脏东西）──
check('收尾：恢复原文件后门禁仍绿', runGate() === 0, '恢复失败 ⇒ 文件被改坏了');

fs.writeFileSync(TARGET, original, 'utf8');
fs.unlinkSync(BACKUP);

console.log(`\n通过 ${passed} / 失败 ${failed}`);
process.exit(failed === 0 ? 0 : 1);
