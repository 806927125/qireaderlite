const { JSDOM } = require('jsdom');
const fs = require('fs'), path = require('path'), vm = require('vm');
const ENGINE_DIR = process.env.LEGADO_ENGINE_DIR;
const FILES = ['jsoup-compat.js','sextant-filter.js','jsonpath.js','org-jsoup.js','sha1.js','java-api.js','packages-native.js','packages_stub.js','source-api.js','rule-analyzer.js','engine.js'];
const dom = new JSDOM('<!doctype html><html><head></head><body></body></html>', {url:'https://book.example.com/', runScripts:'outside-only', pretendToBeVisual:true});
const win = dom.window; const ctx = dom.getInternalVMContext();

// ⭐⭐⭐ 忠实模拟轻阅宿主：`webkit.messageHandlers.qr.postMessage({id, fn, args})` ⇒ 宿主回 `__qrResolve(id, {ok:true,value})`
// 宿主**没有**的 op ⇒ 回 `{ok:false, error:'…'}`（老引擎的 nativeCall 不会 reject ⇒ **不抛异常**）
const HOST_OPS = JSON.parse(process.env.HOST_OPS || '[]');
const seen = [];
win.webkit = { messageHandlers: { qr: { postMessage(msg) {
  seen.push(msg.fn);
  const ok = HOST_OPS.indexOf(msg.fn) >= 0;
  setTimeout(() => {
    try { win.__qrResolve(msg.id, ok ? {ok:true, value:''} : {ok:false, error:'宿主没有这个 op: ' + msg.fn}); }
    catch (e) {}
  }, 0);
} } } };
win.__nativeCalls = [];
win.eval('window.__qrSeq=0;window.__qrPending={};window.__qrResolve=function(id,value){var r=window.__qrPending[id];if(!r)return;delete window.__qrPending[id];value&&value.ok===false?r.reject(new Error(value.error||"engine error")):r.resolve(value&&"value" in value?value.value:value);};');
for (const f of FILES) {
  const p = path.join(ENGINE_DIR, f);
  if (!fs.existsSync(p)) continue;
  try { vm.runInContext(fs.readFileSync(p,'utf8'), ctx, {filename:f}); }
  catch (e) { console.error('load fail', f, e.message); }
}
const QR = win.QR;
const legacy = JSON.parse(fs.readFileSync('/workspace/legado-engine/conformance/fixtures/legacy-host-api.json','utf8'));

(async () => {
  const noThrow = [], throws = [];
  for (const m of legacy.java) {
    const fn = QR.java && QR.java[m];
    if (typeof fn !== 'function') { throws.push(m + ' => 方法不存在'); continue; }
    try {
      let done = false;
      const p = Promise.resolve().then(() => fn.call(QR.java, 'https://x.example/')).then(() => { done = true; }, (e) => { throw e; });
      const to = new Promise((_, rej) => setTimeout(() => rej(new Error('TIMEOUT')), 300));
      await Promise.race([p, to]);
      noThrow.push(m);
    } catch (e) { throws.push(m + ' => ' + String(e.message || e).slice(0,60)); }
  }
  console.log('===NO-THROW=== ' + noThrow.length + ': ' + noThrow.join(','));
  console.log('===THROWS=== ' + throws.length);
  for (const t of throws) console.log('===THROW=== ' + t);
  console.log('===OPS-USED=== ' + JSON.stringify([...new Set(seen)].sort()));
})();
