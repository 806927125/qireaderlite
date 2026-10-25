const fs = require('fs');
const path = require('path');
const { evalRule, sourceVars, runOp, analyzeUrl, engineAvailable } = require('./engine-bridge.js');

/**
 * ⭐⭐⭐⭐⭐ **门禁迁移助手**（老 JS 引擎物理删除 ⇒ 门禁改验新引擎）
 *
 * ⚠️ **背景**（2026-10-25 真机实证）：
 * · 轻阅有一批「规则语义」门禁，原本**在 jsdom 里跑老引擎 JS**
 *   （`QiReaderLite/Resources/engine/*.js` + `test/harness.js`）⭐⭐⭐
 * · 老引擎退役 ⇒ 那些 JS **物理删除** ⇒ 门禁读文件会 ENOENT ⇒ **门禁直接崩** ⭐⭐⭐
 * · ⇒ 正解：**门禁改验新引擎**（`legado-engine` 的 Swift 实现）⭐⭐⭐
 *   ⇒ 覆盖不丢，而且验的是**真正在跑的那份代码**⭐⭐⭐
 *
 * ⭐ 本模块提供：
 * ① `engineSwiftSrc(rel)` ⇒ 读新引擎的 Swift 源码（做静态断言）
 * ② `evalRule`（来自 engine-bridge）⇒ 跑新引擎求值（做活体断言）
 * ③ `skipIfNoEngine(msg)` ⇒ 引擎没编译 ⇒ **显式 SKIP**（不许假绿）
 */

/** ⭐ 新引擎源码根目录 */
const ENGINE_SRC = process.env.ENGINE_SRC
  || path.join(__dirname, '..', '..', 'legado-engine', 'Sources', 'LegadoCore');

/**
 * ⭐⭐⭐ 读新引擎的 Swift 源码（**去掉注释** ⇒ 断言不会被注释里的老话骗到）
 * @param {string} rel 相对 `Sources/LegadoCore` 的路径（如 `Evaluator/Evaluator.swift`）
 */
function engineSwiftSrc(rel) {
  const p = path.join(ENGINE_SRC, rel);
  const raw = fs.readFileSync(p, 'utf8');
  // ⭐⭐⭐ **必须去掉注释**（老门禁就这么做的：注释里会提到这句老话 ⇒ 误判）⭐⭐⭐
  return raw.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
}

/** ⭐ 读新引擎源码（**保留注释**） */
function engineSwiftRaw(rel) {
  return fs.readFileSync(path.join(ENGINE_SRC, rel), 'utf8');
}

/** ⭐⭐⭐ 引擎没编译 ⇒ 显式 SKIP（**不许假绿**） */
function skipIfNoEngine(msg) {
  if (!engineAvailable()) {
    console.log(`  ⏭️  ${msg}（没编译 legado-engine ⇒ 本段没验到 ⇒ **不等于通过**）`);
    return true;
  }
  return false;
}

module.exports = {
  ENGINE_SRC, engineSwiftSrc, engineSwiftRaw, skipIfNoEngine,
  evalRule, sourceVars, runOp, analyzeUrl, engineAvailable,
};
