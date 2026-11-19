#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁入口：站方 exploreUrl 的分类归一化 —— 旧引擎 JS ⇔ 新 Swift 双实现对拍**
 *
 * ⚠️ **为什么要有它**（2026-11-19 真机 build296 实证）：
 *   真机报「发现页：未能完成操作。（LegadoEngine.LegadoError 错误 1。）」
 *   引擎日志：`新引擎跑「explore」失败：url 解析失败:`（**冒号后为空**）
 *   ⇒ 根因 = 换装新引擎后丢了「先求值 `@js:` 的 exploreUrl」这条能力 ⇒ 分类 url 为空 ⭐⭐⭐
 *
 * ⭐ **权威规格 = 已删的旧引擎**（git `0b5c481^` 的 `engine.js` / `jsoup-compat.js`）
 *   ⇒ 门禁把那三个函数原样抽出来当 oracle ⇒ 新 Swift 实现必须逐字段一致 ⭐⭐⭐
 *
 * （真正的对拍逻辑在 `test/explore-kinds-parity.js`；本文件只是总门禁的统一入口）
 */
const { execFileSync } = require('child_process');
const path = require('path');

try {
  execFileSync('node', [path.join(__dirname, 'explore-kinds-parity.js')], {
    stdio: 'inherit', maxBuffer: 64 * 1024 * 1024,
  });
} catch (e) {
  process.exit(e.status === undefined ? 1 : e.status);
}
