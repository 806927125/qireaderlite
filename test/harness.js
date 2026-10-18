const { JSDOM } = require('jsdom');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ENGINE_DIR = path.join(__dirname, '..', 'QiReaderLite', 'Resources', 'engine');
// 顺序必须与 QiReaderLite/Core/RuleSandbox.swift 的 ResourceLocator.scripts 完全一致 ——
// 不一致会让"沙盒能跑、真机不跑"或者反过来。
const FILES = [
  'jsoup-compat.js',
  'jsonpath.js',
  'org-jsoup.js',
  'sha1.js',
  'java-api.js',
  'packages-native.js',   // Packages.* 的原生函数实现（必须在 packages_stub.js 前）
  'packages_stub.js',     // Packages / JavaImporter / importPackage 兼容层
  'rule-analyzer.js',
  'engine.js',
];

/**
 * 在 jsdom 里造一个跟 WKWebView 一样形状的沙盒：
 * 有 DOM、有 location、有 btoa/atob，但**没有**原生 HTTP 桥，
 * 请求全部走 mock 队列 —— 逼引擎的兜底分支在测试里也真跑一遍。
 */
function createSandbox({ origin = 'https://book.example.com/', nativeMock = null } = {}) {
  const calls = [];
  const dom = new JSDOM('<!doctype html><html><head></head><body></body></html>',
    { url: origin, runScripts: 'outside-only', pretendToBeVisual: true });
  const win = dom.window;
  const ctx = dom.getInternalVMContext();

  win.__nativeCalls = calls;
  win.__nativeMock = nativeMock || (async (fn, args) => ({ ok: true, value: '' }));
  win.webkit = {
    messageHandlers: {
      qr: {
        postMessage(msg) {
          calls.push(msg);
          Promise.resolve(win.__nativeMock(msg.fn, msg.args || {}))
            .then(r => win.__qrResolve(msg.id, r))
            .catch(e => win.__qrResolve(msg.id, { ok: false, error: String(e && e.message || e) }));
        }
      }
    }
  };

  // 引擎的宿主脚本
  win.eval(`
    window.__qrSeq = 0;
    window.__qrPending = {};
    window.__qrResolve = function (id, value) {
      var r = window.__qrPending[id];
      if (!r) return;
      delete window.__qrPending[id];
      value && value.ok === false ? r.reject(new Error(value.error || 'engine error')) : r.resolve(value && 'value' in value ? value.value : value);
    };
  `);

  for (const f of FILES) {
    const p = path.join(ENGINE_DIR, f);
    if (!fs.existsSync(p)) continue;
    vm.runInContext(fs.readFileSync(p, 'utf8'), ctx, { filename: f });
  }
  return { dom, win, ctx, calls, QR: win.QR };
}

module.exports = { createSandbox, ENGINE_DIR, FILES };
