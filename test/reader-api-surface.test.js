#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：宿主适配层的公开 API 清单不许缺**（2026-11-25 改写）⭐⭐⭐⭐⭐
 *
 * ⚠️⚠️⚠️ **为什么要有这条门禁**（血坑实录）⭐⭐⭐：
 *   上一版钉的是 `Core/ReaderSession.swift`（我们自己的阅读会话）与
 *   `Features/Reader/Paging/*`（我们自己的分页器）的成员清单
 *   ⇒ 2026-11-25 那些**整套删掉**（换成柴阅的阅读器）⇒ 清单必须跟着换对象 ⭐⭐⭐
 *   ⇒ 新的清单 = **宿主适配层**（`Features/Reader/Chaiyue/`）的成员 ⭐⭐⭐
 *   ⇒ 因为它也是「按标记切代码」切出来的 ⇒ **切错一个成员 ⇒ 只有 Xcode 编译抓得到**
 *     ⇒ 沙盒里就得能红 ⭐⭐⭐
 *
 * ⭐⭐⭐⭐⭐ **判据原则** ⭐⭐⭐⭐⭐：
 *   只钉「对外承诺的成员」（谁在调它），内部实现随便改；
 *   但**少一个就红**（这正是切代码最容易犯的错）⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..', 'QiReaderLite');
const CHAIYUE = path.join(ROOT, 'Features/Reader/Chaiyue');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓', m); }
  else { fail++; console.log('  ✗', m, extra === undefined ? '' : '→ ' + extra); }
};
function stripComments(src) {
  return src.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/\/\/[^\n]*/g, ' ');
}
const readChaiyue = (rel) => {
  const p = path.join(CHAIYUE, rel);
  return fs.existsSync(p) ? stripComments(fs.readFileSync(p, 'utf8')) : '';
};

// ── ① ⭐⭐⭐ 适配层：我们的模型 → 柴阅模型（谁在调它，谁就钉死）⭐⭐⭐
{
  const adapter = readChaiyue('ChaiyueReaderAdapter.swift');
  ok(adapter.length > 0, '① 适配层文件在（ChaiyueReaderAdapter.swift）');
  for (const [needle, label] of [
    ['static func book(', 'book（我们的书 → 柴阅的书）'],
    ['static func chapter(', 'chapter（我们的章 → 柴阅的章）'],
    ['static func chapters(', 'chapters（整张目录 → 柴阅的目录）'],
    ['static func source(', 'source（我们的书源 → 柴阅的书源）'],
  ]) {
    ok(adapter.includes(needle), `① 适配层成员还在：${label}`, needle);
  }
  // ⭐⭐⭐ 三个「宿主自己的类型」别名（避��柴阅同名类型撞名）⭐⭐⭐
  for (const alias of ['typealias QiBook =', 'typealias QiChapter =', 'typealias QiBookSource =']) {
    ok(adapter.includes(alias), `① 宿主别名还在：${alias}`);
  }
}

// ── ② ⭐⭐⭐ 门面：柴阅的 `ChaiyueReaderLibrary` 实现（shim 在宿主侧）⭐⭐⭐
{
  const host = readChaiyue('ChaiyueReaderHost.swift');
  ok(host.length > 0, '② 宿主门面文件在（ChaiyueReaderHost.swift）');
  ok(/class ChaiyueHostLibrary\s*:\s*ChaiyueReaderLibrary/.test(host),
     '② 宿主侧实现了柴阅的 `ChaiyueReaderLibrary`');
  for (const [needle, label] of [
    ['let shelf: BookshelfRepository', 'shelf（柴阅的书架仓）'],
    ['let sources: SourceRepository', 'sources（柴阅的书源仓）'],
    ['let httpTTS: HttpTTSRepository', 'httpTTS（在线朗读源仓）'],
    ['let chapterStore: ChapterStore', 'chapterStore（章节缓存）'],
    ['let readingRecords: ReadingRecordStore', 'readingRecords（阅读记录）'],
    ['func readerSession(for book:', 'readerSession(for:)（造柴阅的阅读会话）'],
    ['func callBack(', 'callBack（书源事件回调）'],
  ]) {
    ok(host.includes(needle), `② 门面成员还在：${label}`, needle);
  }
  // ⚠️⚠️ **会话缓存**：界面与宿主必须共用同一份会话，否则进度分叉 ⭐⭐⭐
  ok(/var sessions: \[String: ReaderSession\]/.test(host), '② 门面对会话做了缓存');
  ok(/if let existing = sessions\[book\.bookUrl\] \{ return existing \}/.test(host),
     '② 同一本书返回同一个会话');
}

// ── ③ ⭐⭐⭐ 宿主对象：把轻阅的数据镜像进柴阅的仓 ⭐⭐⭐
{
  const host = readChaiyue('ChaiyueReaderHost.swift');
  for (const [needle, label] of [
    ['let app: AppModel', 'app（柴阅的 AppModel）'],
    ['let launch: ReaderLaunch', 'launch（柴阅的打开请求）'],
    ['let session: ReaderSession', 'session（共享的阅读会话）'],
    ['let model: ReaderModel', 'model（柴阅的阅读模型）'],
    ['let library: ChaiyueHostLibrary', 'library（门面）'],
    ['func writeBackProgress(to', 'writeBackProgress（进度回写轻阅书库）'],
  ]) {
    ok(host.includes(needle), `③ 宿主成员还在：${label}`, needle);
  }
  // 镜像三件事：书源 / 目录 / 书架
  ok(/importSources\(/.test(host), '③ 轻阅的书源镜像进柴阅的书源仓');
  ok(/saveChapters\(/.test(host), '③ 轻阅的目录预写进柴阅的章节缓存');
  ok(/shelf\.add\(/.test(host), '③ 轻阅的书库镜像进柴阅的书架仓');
}

// ── ④ ⭐⭐⭐ 阅读视图：柴阅的 `ReaderContainer` + `AppModel` 环境 ⭐⭐⭐
{
  const screen = readChaiyue('ChaiyueReaderScreen.swift');
  ok(screen.length > 0, '④ 阅读视图文件在（ChaiyueReaderScreen.swift）');
  ok(/ReaderContainer\(launch:/.test(screen), '④ 打开的是柴阅的 `ReaderContainer`');
  ok(/\.environment\(host\.app\)|\.environment\(/.test(screen), '④ 注入了 `AppModel` 环境');
  ok(/onChange\(of: host\?\.app\.reader\)/.test(screen), '④ 柴阅关掉阅读器时宿主跟着收摊');
}

// ── ⑤ ⭐⭐⭐ 被删掉的老 API 不许复活 ⭐⭐⭐
{
  const old = path.join(ROOT, 'Core/ReaderSession.swift');
  ok(!fs.existsSync(old), '⑤ 我们自己的 `Core/ReaderSession.swift` 已删（柴阅的会话顶上）');
}

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}\n`);
process.exit(fail === 0 ? 0 : 1);
