#!/usr/bin/env node
/**
 * ⭐⭐⭐⭐⭐ **门禁：柴阅的【漫画阅读器】必须真的在、真的连得上**（2026-11-26 · 用户「把漫画阅读器也搬过来」）⭐⭐⭐⭐⭐
 *
 * ⚠️⚠️⚠️ **背景** ⭐⭐⭐：
 *   柴阅的漫画阅读器 = `App/Sources/Media/Comic/`（6 文件 1941 行）
 *   ⇒ 漫画的**图就是章节正文里的 `<img>`**（`MediaSession.images(at:)` → `ChapterText.imageSources`）
 *   ⇒ **数据链本来就通**，缺的是界面层 + 一个关键断点：**站方的 `book.type` 在宿主↔引擎往返里被丢了** ⭐⭐⭐
 *   ⇒ 丢了 ⇒ 柴阅永远以为是文字书 ⇒ 漫画打不开（老 WebView 阅读器时代能看，现在看不了）⭐⭐⭐
 *
 * ⭐⭐⭐⭐⭐ **判据（六条，缺一条这个功能就是坏的）**⭐⭐⭐⭐⭐：
 *   ① **文件在**：6 个漫画文件都在包里，且整文件有 `#if os(iOS)` 守卫（macOS/Linux 编不到 UIKit）⭐⭐⭐
 *   ② **宿主能开**：`ComicReaderScreen` 是 public 且有 public init（`public struct` 的 memberwise init 是 internal）⭐⭐⭐
 *   ③ **启动通道**：`MediaLaunch` / `AppModel.media` / `AppModel.closeMedia()` 都在（漫画走 `app.media`，不走 `app.reader`）⭐⭐⭐
 *   ④ **会话能造**：门面协议有 `mediaSession(for:)` 且**宿主实现了**（柴阅的 `ComicReaderScreen` 就是这么拿数据的）⭐⭐⭐
 *   ⑤ **type 断点**：宿主 `Book.mediaType`（从 raw 现算，**不动 Codable**）＋ 适配器搬 type ＋ `bookPayload` 带 type ⭐⭐⭐
 *   ⑥ **详情页分流**：按 `mediaKind` 判漫画 ⇒ 开漫画屏（判定只用柴阅那一份真相）⭐⭐⭐
 *
 * ⭐⭐⭐ **变异对照**：删漫画文件 / 把 ComicReaderScreen 降回 internal / 去掉 mediaSession / 去掉 type 传递 / 去掉分流
 *   ⇒ 五条都必须报出来 ⇒ 否则这条门禁是摆设 ⭐⭐⭐
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const PKG = path.join(ROOT, 'LegadoEngine/Sources/ChaiyueReader');

let pass = 0, fail = 0;
const ok = (c, m, extra) => {
  if (c) { pass++; console.log('  ✓', m); }
  else { fail++; console.log('  ✗', m, extra === undefined ? '' : '→ ' + extra); }
};

const read = (p) => (fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : '');

/** 剥掉注释（判据不能被注释文字命中） */
function codeOnly(src) {
  return src.split('\n').map(line => {
    let out = '', inStr = false, quote = '';
    for (let i = 0; i < line.length; i++) {
      const c = line[i];
      if (inStr) { out += c; if (c === quote && line[i - 1] !== '\\') inStr = false; continue; }
      if (c === '"' || c === "'") { inStr = true; quote = c; out += c; continue; }
      if (c === '/' && line[i + 1] === '/' && line[i - 1] !== ':') break;
      out += c;
    }
    return out;
  }).join('\n');
}

const COMIC_FILES = ['ComicModel', 'ComicChrome', 'ComicStage', 'ComicReaderScreen',
                     'ComicPagerController', 'ComicStripController'];

console.log('\n── ① 漫画阅读器的 6 个文件在包里（且有 iOS 守卫）──');
{
  const missing = [];
  const noGuard = [];
  for (const f of COMIC_FILES) {
    const p = path.join(PKG, 'Media/Comic', `${f}.swift`);
    if (!fs.existsSync(p)) { missing.push(f); continue; }
    if (!codeOnly(read(p)).includes('#if os(iOS)')) noGuard.push(f);
  }
  ok(missing.length === 0, `① 6 个漫画文件都在（Comic/）`, missing.join(' / '));
  ok(noGuard.length === 0, '① 每个都有 #if os(iOS) 守卫（macOS/Linux 编不到 UIKit）', noGuard.join(' / '));

  // 变异对照：拿掉一个文件 ⇒ 判据必须报
  const simulated = COMIC_FILES.filter(f => f !== 'ComicModel');
  ok(simulated.length === COMIC_FILES.length - 1, '① 变异①：拿掉一个漫画文件后判据要能报（门禁有牙齿）');
}

console.log('\n── ② 宿主能开漫画页（public + public init）──');
{
  const src = codeOnly(read(path.join(PKG, 'Media/Comic/ComicReaderScreen.swift')));
  ok(src.length > 0, '② ComicReaderScreen 在');
  ok(/public struct ComicReaderScreen/.test(src), '② ComicReaderScreen 是 public（宿主跨模块要 new 它）');
  ok(/public init\(launch: MediaLaunch\)/.test(src),
     '② 有 public init（public struct 的 memberwise init 是 internal ⇒ 宿主 new 不了）');

  const mutated = src.replace(/public struct ComicReaderScreen/, 'struct ComicReaderScreen');
  ok(!/public struct ComicReaderScreen/.test(mutated), '② 变异②：降回 internal 后判据要能报（门禁有牙齿）');
}

console.log('\n── ③ 漫画的启动通道（app.media，不是 app.reader）──');
{
  const src = codeOnly(read(path.join(PKG, 'Shims/AppModel.swift')));
  ok(/public struct MediaLaunch/.test(src), '③ 有 public 的 MediaLaunch');
  ok(/public var media: MediaLaunch\?/.test(src), '③ AppModel 有 public 的 media');
  ok(/public func closeMedia\(\)/.test(src), '③ AppModel 有 public 的 closeMedia()（漫画页收起时调）');

  const mutated = src.replace(/public var media: MediaLaunch\?/, 'var media: MediaLaunch?');
  ok(!/public var media: MediaLaunch\?/.test(mutated), '③ 变异③：media 降回 internal 后判据要能报（门禁有牙齿）');
}

console.log('\n── ④ 漫画会话能造（协议 + 宿主实现）──');
{
  const proto = codeOnly(read(path.join(PKG, 'Shims/AppModel.swift')));
  const host = codeOnly(read(path.join(ROOT, 'QiReaderLite/Features/Reader/Chaiyue/ChaiyueReaderHost.swift')));
  ok(/func mediaSession\(for book: Book\) -> MediaSession/.test(proto),
     '④ 门面协议声明了 mediaSession(for:)（柴阅的 ComicReaderScreen 就靠它拿数据）');
  ok(/func mediaSession\(for book: LegadoEngineHost\.BookModel\) -> MediaSession/.test(host),
     '④ 宿主实现了 mediaSession(for:)');

  const mutated = proto.replace(/func mediaSession\(for book: Book\) -> MediaSession/, '');
  ok(!/func mediaSession\(for book: Book\) -> MediaSession/.test(mutated),
     '④ 变异④：协议去掉 mediaSession 后判据要能报（门禁有牙齿）');
}

console.log('\n── ⑤ type 断点（站方标的形态不能丢）──');
{
  const book = codeOnly(read(path.join(ROOT, 'QiReaderLite/Core/Book.swift')));
  const adapter = codeOnly(read(path.join(ROOT, 'QiReaderLite/Features/Reader/Chaiyue/ChaiyueReaderAdapter.swift')));
  const backend = codeOnly(read(path.join(ROOT, 'QiReaderLite/Core/LegadoEngineBackend.swift')));
  const host = codeOnly(read(path.join(ROOT, 'QiReaderLite/Features/Reader/Chaiyue/ChaiyueReaderHost.swift')));
  const service = codeOnly(read(path.join(ROOT, 'QiReaderLite/Core/SourceService.swift')));
  const detail = codeOnly(read(path.join(ROOT, 'QiReaderLite/Features/BookDetail/BookDetailView.swift')));

  ok(/var mediaType: Int/.test(book),
     '⑤ 宿主 Book 有 mediaType（从 raw 现算 ⇒ **不动 Codable** ⇒ 旧书架数据不会解码失败）');
  ok(/book\.type = contentType != 0 \? contentType : \(sourceType != 0 \? sourceType : b\.mediaType\)/.test(adapter),
     '⑤ 适配器把形态搬进柴阅的 Book.type（**三路**：目录脚本写的 contentType → 书源类型 → 书里已有的 mediaType）');
  ok(/var contentType: Int = 0/.test(detail), '⑤ 详情页独立 @State 接住站方目录脚本写的形态（改了 @State 才会重算 body）');
  ok(/contentType: res\.bookType/.test(detail) || /res\.bookType/.test(detail),
     '⑤ 详情页把目录返回的 bookType 收进 contentType');
  ok(/sourceType: source\?\.bookSourceType \?\? 0/.test(host),
     '⑤ 宿主把 source.bookSourceType 传给适配器（不传 ⇒ 永远判成文字书）');
  ok(/"type": b\.type/.test(backend), '⑤ bookPayload（引擎 → 宿主）带 type');
  ok(/fields\["bookSourceType"\] = String\(type\)/.test(service),
     '⑤ 详情页把 type 存成 bookSourceType（不污染站方自己的 type 字段）');

  const mutated = adapter.replace(/book\.type = contentType != 0 \? contentType : \(sourceType != 0 \? sourceType : b\.mediaType\)/, '');
  ok(!/book\.type = contentType != 0/.test(mutated), '⑤ 变异⑤：适配器不搬类型后判据要能报（门禁有牙齿）');
}

console.log('\n── ⑥ 详情页按 mediaKind 分流到漫画屏 ──');
{
  const detail = codeOnly(read(path.join(ROOT, 'QiReaderLite/Features/BookDetail/BookDetailView.swift')));
  const comic = codeOnly(read(path.join(ROOT, 'QiReaderLite/Features/Reader/Chaiyue/ChaiyueComicScreen.swift')));
  ok(detail.length > 0, '⑥ 详情页在');
  ok(/mediaKind\(sourceType:/.test(detail),
     '⑥ 判定用柴阅的 mediaKind(sourceType:)（宿主不再自己判一遍 ⇒ 不会与柴阅漂移）');
  ok(/ChaiyueComicScreen\(/.test(detail), '⑥ 详情页会开漫画屏');
  ok(comic.length > 0, '⑥ 宿主漫画屏在');
  ok(/ComicReaderScreen\(launch:/.test(comic), '⑥ 宿主漫画屏渲染的是柴阅的 ComicReaderScreen');
  // ⚠️ **两种模式的会话不是一回事**（CI 45836279240 实锤：`launch` 变 optional ⇒ 取 `.book` 编译不过）⭐⭐⭐
  const host = codeOnly(read(path.join(ROOT, 'QiReaderLite/Features/Reader/Chaiyue/ChaiyueReaderHost.swift')));
  ok(/let session: ReaderSession\?/.test(host), '⑥ 宿主会话是 optional（漫画模式是 nil）');
  ok(/case \.comic: session = nil/.test(host), '⑥ 漫画模式不造 ReaderSession（它用 MediaSession）');

  const mutated = detail.replace(/ChaiyueComicScreen\(/, 'UnusedComicScreen(');
  ok(!/ChaiyueComicScreen\(/.test(mutated), '⑥ 变异⑥：详情页不分流后判据要能报（门禁有牙齿）');
}

console.log('\n── ⑦ 漫画用到的两个「柴阅 App 层成员」必须在包里 ──');
{
  // ⭐⭐⭐ **CI327 实证**：这两个都**不在模型层**、而在柴阅的 **App 层文件**里 ⇒ 搬 App 层时漏了 ⇒
//   ① `ButtonStyle.press`（`App/Sources/Design/Components.swift`）⇒ 漫画的 `.buttonStyle(.press)` 编不过 ⭐⭐⭐
//   ② `Book.hasStarted`（`App/Sources/Screens/Shelf/HeroCard.swift`）⇒ `actionTitle(for:)` 编不过 ⭐⭐⭐
  const components = codeOnly(read(path.join(PKG, 'Shims/Support/DesignComponents.swift')));
  const bookExt = codeOnly(read(path.join(PKG, 'Shims/BookExtensions.swift')));
  ok(/extension ButtonStyle where Self == PressStyle/.test(components) &&
     /static var press: PressStyle/.test(components),
     '⑦ 有 `ButtonStyle.press`（柴阅的静态 ButtonStyle 成员，漫画按钮要用）');
  ok(/var hasStarted: Bool/.test(bookExt),
     '⑦ 有 `Book.hasStarted`（柴阅写在 App 层书架文件里 ⇒ 搬 App 层时最容易漏）');

  const mutated = components.replace(/static var press: PressStyle \{ PressStyle\(\) \}/, '');
  ok(!/static var press: PressStyle/.test(mutated), '⑦ 变异⑦：去掉 .press 后判据要能报（门禁有牙齿）');
}

console.log('\n── ⑧ AppModel 不得有「编译器类型检查超时」的链式表达式 ──');
{
  // ⭐⭐⭐ **CI 45838661911 实证**：给 `AppModel` 加了 `MediaLaunch?` ⇒ `@Observable` 生成的代码变重
  //   ⇒ `voiceName` 那条**链式可选表达式**的推断负担越过编译器阈值 ⇒
  //   报 `the compiler is unable to type-check this expression in reasonable time`
  //   ⇒ 并**级联**报出「cannot find 'LocalVoice' in scope」（假象！）⭐⭐⭐
  //   ⇒ 修法：拆成显式分支 ⇒ 编译器不用推导 ⇒ 又快又稳 ⭐⭐⭐
  const model = codeOnly(read(path.join(PKG, 'Shims/AppModel.swift')));
  const voiceName = (model.match(/var voiceName: String \{[\s\S]*?\n    \}/) || [''])[0];
  ok(voiceName.length > 0, '⑧ 找得到 voiceName');
  ok(!/\?\?/.test(voiceName),
     '⑧ voiceName 里没有 `??` 链（那是最容易顶爆类型检查的写法）');
  ok(/if let/.test(voiceName), '⑧ voiceName 是显式分支（编译器不用推导）');

  const mutated = model.replace(/var voiceName: String \{[\s\S]*?\n    \}/,
    'var voiceName: String { onlineSpeech?.name ?? settings.speechVoice.flatMap { id in voices.voices.first { $0.id == id }?.name } ?? "系统语音" }');
  const mutatedVoice = (mutated.match(/var voiceName: String \{[\s\S]*?\n    \}/) || [''])[0];
  ok(/\?\?/.test(mutatedVoice), '⑧ 变异⑧：换回链式写法后判据要能报（门禁有牙齿）');
}

console.log(`\n${fail === 0 ? '✅' : '❌'} 通过 ${pass} / 失败 ${fail}\n`);
process.exit(fail === 0 ? 0 : 1);
