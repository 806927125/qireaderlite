// ⭐⭐⭐⭐⭐ **平台条件编译补丁**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **为什么需要**：阅读器界面用满 UIKit（`UIScreen` / `UIApplication` / `UIImpactFeedbackGenerator` …）
//   ⇒ **iOS-only** ⇒ Linux 沙盒编不到 SwiftUI/UIKit ⇒ 若不隔离，**整个包的 Linux 编译门禁全废** ⭐⭐⭐
//   ⇒ 用 `#if canImport(UIKit)` 包裹：**Apple 平台功能完全不变**，Linux 上跳过这段界面代码 ⭐⭐⭐
//   ⇒ 与上游的 diff 仅此两行（去掉即可回到柴阅原样）⭐⭐⭐
#if os(iOS)
import Foundation
import ImageIO
import Observation
import ChaiyueReaderKit
import UIKit
import UniformTypeIdentifiers
import ZIPFoundation

/// 主题的渲染方式
enum ReaderThemeMode: String, Codable, Hashable {
    /// 原生排版（CSS 子集 + 脚本钩子），五种翻页动画、朗读高亮、长按选字都可用
    case native
    /// 网页渲染：整页交给 WebKit，完整的 CSS / JavaScript / HTML 装饰层
    case web
}

/// 用户自定义的阅读主题：一份样式表、一份脚本，外加样式表里 `url(文件名)` 引用的素材
struct CustomReaderTheme: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var css: String
    var js: String
    var updated: Date
    var mode: ReaderThemeMode = .native
    /// 网页模式的装饰层，插在纸面里、正文之下
    var html: String = ""

    init(id: String, name: String, css: String, js: String, updated: Date, mode: ReaderThemeMode = .native, html: String = "") {
        self.id = id
        self.name = name
        self.css = css
        self.js = js
        self.updated = updated
        self.mode = mode
        self.html = html
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        css = try c.decode(String.self, forKey: .css)
        js = try c.decode(String.self, forKey: .js)
        updated = try c.decode(Date.self, forKey: .updated)
        mode = try c.decodeIfPresent(ReaderThemeMode.self, forKey: .mode) ?? .native
        html = try c.decodeIfPresent(String.self, forKey: .html) ?? ""
    }
}

/// 自定义主题库：Application Support/ReaderThemes 下 `index.json` 存主题，`<id>/` 放图片
@Observable
final class ReaderThemeStore {
    static let shared = ReaderThemeStore()

    nonisolated static let fileExtension = "chaiyuetheme"
    static let importTypes: [UTType] = [.json, .plainText, .data, .zip, .html]
        + [fileExtension, "css"].compactMap { UTType(filenameExtension: $0) }

    private(set) var themes: [CustomReaderTheme] = []
    /// 主题内容变化后递增，阅读页据此重排
    private(set) var revision = 0

    @ObservationIgnored private var sheets: [String: (Date, ReaderStyleSheet)] = [:]
    @ObservationIgnored private var scripts: [String: (Date, ReaderThemeScript)] = [:]
    @ObservationIgnored private var images: [String: UIImage] = [:]
    /// 主题选择卡片上的小图，按最长边 180 像素缩小后缓存
    @ObservationIgnored private var previews: [String: UIImage] = [:]

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "ReaderThemes", directoryHint: .isDirectory)
    }

    private static var indexURL: URL { directory.appending(path: "index.json") }

    private init() {
        if let data = try? Data(contentsOf: Self.indexURL),
           let list = try? JSONDecoder().decode([CustomReaderTheme].self, from: data) {
            themes = list
        }
    }

    func theme(_ id: String?) -> CustomReaderTheme? {
        guard let id else { return nil }
        return themes.first { $0.id == id }
    }

    // MARK: - 增删改

    @discardableResult
    func create(name: String, css: String, js: String, mode: ReaderThemeMode = .native, html: String = "") -> CustomReaderTheme {
        let theme = CustomReaderTheme(id: UUID().uuidString, name: uniqueName(name), css: css, js: js, updated: Date(),
                                      mode: mode, html: html)
        themes.insert(theme, at: 0)
        persist()
        return theme
    }

    func save(_ theme: CustomReaderTheme) {
        var item = theme
        item.updated = Date()
        if let index = themes.firstIndex(where: { $0.id == theme.id }) {
            themes[index] = item
        } else {
            themes.insert(item, at: 0)
        }
        sheets[theme.id] = nil
        scripts[theme.id] = nil
        persist()
    }

    @discardableResult
    func duplicate(_ theme: CustomReaderTheme) -> CustomReaderTheme {
        let copy = create(name: theme.name + " 副本", css: theme.css, js: theme.js, mode: theme.mode, html: theme.html)
        let fm = FileManager.default
        for name in imageNames(theme.id) {
            try? fm.createDirectory(at: folder(copy.id), withIntermediateDirectories: true)
            try? fm.copyItem(at: folder(theme.id).appending(path: name), to: folder(copy.id).appending(path: name))
        }
        return copy
    }

    func remove(_ theme: CustomReaderTheme) {
        themes.removeAll { $0.id == theme.id }
        try? FileManager.default.removeItem(at: folder(theme.id))
        sheets[theme.id] = nil
        scripts[theme.id] = nil
        previews[theme.id] = nil
        images = images.filter { !$0.key.hasPrefix(theme.id + "/") }
        persist()
    }

    private func uniqueName(_ name: String) -> String {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "我的主题" : name
        var candidate = base
        var n = 2
        while themes.contains(where: { $0.name == candidate }) {
            candidate = "\(base) \(n)"
            n += 1
        }
        return candidate
    }

    private func persist() {
        revision += 1
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            try encoder.encode(themes).write(to: Self.indexURL, options: .atomic)
        } catch {
            print("保存阅读主题失败：\(error)")
        }
    }

    // MARK: - 解析缓存

    func sheet(for theme: CustomReaderTheme) -> ReaderStyleSheet {
        if let cached = sheets[theme.id], cached.0 == theme.updated { return cached.1 }
        let sheet = ReaderStyleSheet(css: theme.css)
        sheets[theme.id] = (theme.updated, sheet)
        return sheet
    }

    /// 没写脚本时为 nil
    func script(for theme: CustomReaderTheme) -> ReaderThemeScript? {
        guard !theme.js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let cached = scripts[theme.id], cached.0 == theme.updated { return cached.1 }
        let script = ReaderThemeScript(source: theme.js)
        scripts[theme.id] = (theme.updated, script)
        return script
    }

    /// 阅读页用的主题规格：纸色与正文色取样式表，没写时用纸张 / 夜间的配色
    func spec(for theme: CustomReaderTheme, dark: Bool) -> ReaderThemeSpec {
        let style = sheet(for: theme).resolve(dark: dark)
        var spec = Self.spec(id: theme.id, name: theme.name, style: style, dark: dark)
        spec.web = theme.mode == .web
        spec.revision = theme.updated
        return spec
    }

    static func spec(id: String, name: String, style: ReaderPageStyle, dark: Bool) -> ReaderThemeSpec {
        let fallback = ReaderThemeSpec.find(dark ? "night" : "paper")!
        var spec = ReaderThemeSpec(id: "custom:\(id)", name: name,
                                   background: style.page.background?.rgb ?? fallback.background,
                                   text: style.body.color?.rgb ?? fallback.text,
                                   secondaryAlpha: fallback.secondaryAlpha,
                                   grain: style.page.grain ?? 0, isDark: dark)
        spec.style = style
        spec.customID = id
        return spec
    }

    // MARK: - 图片

    private func folder(_ id: String) -> URL { Self.directory.appending(path: id, directoryHint: .isDirectory) }

    func imageNames(_ id: String) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder(id).path)) ?? []
        return files.filter { !$0.hasPrefix(".") }.sorted()
    }

    /// 主题卡片用的代表图：素材里体积最大的那张，缩小后缓存
    func previewImage(_ id: String) -> UIImage? {
        if let cached = previews[id] { return cached }
        let allowed = ["png", "jpg", "jpeg", "webp"]
        let names = imageNames(id).filter { allowed.contains(($0 as NSString).pathExtension.lowercased()) }
        guard let name = names.max(by: { fileSize(id, $0) < fileSize(id, $1) }) else { return nil }
        let url = folder(id).appending(path: name) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 180,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = UIImage(cgImage: cg, scale: 2, orientation: .up)
        previews[id] = image
        return image
    }

    private func fileSize(_ id: String, _ name: String) -> Int {
        let path = folder(id).appending(path: name).path
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber
        return size?.intValue ?? 0
    }

    func image(_ id: String, named name: String) -> UIImage? {
        let key = "\(id)/\(name)"
        if let cached = images[key] { return cached }
        guard let image = UIImage(contentsOfFile: folder(id).appending(path: (name as NSString).lastPathComponent).path) else { return nil }
        images[key] = image
        return image
    }

    /// 复制图片进主题目录，返回在样式表里引用用的文件名
    func addImage(_ url: URL, to id: String) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: folder(id), withIntermediateDirectories: true)
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        var name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: " ", with: "-") + "." + ext
        var n = 2
        while fm.fileExists(atPath: folder(id).appending(path: name).path) {
            name = url.deletingPathExtension().lastPathComponent + "-\(n)." + ext
            n += 1
        }
        try fm.copyItem(at: url, to: folder(id).appending(path: name))
        revision += 1
        return name
    }

    func removeImage(_ name: String, from id: String) {
        try? FileManager.default.removeItem(at: folder(id).appending(path: name))
        images["\(id)/\(name)"] = nil
        revision += 1
    }

    /// 主题素材的文件地址（网页模式的 `chaiyue://theme/文件名` 由它取文件）
    func fileURL(_ id: String, named name: String) -> URL {
        folder(id).appending(path: (name as NSString).lastPathComponent)
    }

    // MARK: - 导入导出

    /// 旧版主题包：一个 JSON，素材以 base64 内嵌
    private struct LegacyPackage: Codable {
        var format = 1
        var name: String
        var css: String
        var js: String
        var images: [String: Data]
    }

    /// 主题包清单（zip 里的 theme.json）
    private struct Manifest: Codable {
        var format = 2
        var name: String
        var mode: ReaderThemeMode
    }

    private enum PackageFile {
        static let manifest = "theme.json"
        static let css = "style.css"
        static let js = "script.js"
        static let html = "page.html"
        static let assets = "assets/"
    }

    /// 导出为 zip 主题包：theme.json + style.css + script.js + page.html + assets/ 素材，解压后能在电脑上直接改
    func exportData(_ theme: CustomReaderTheme) throws -> Data {
        let archive = try Archive(accessMode: .create)
        func add(_ path: String, _ data: Data) throws {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try add(PackageFile.manifest, try encoder.encode(Manifest(name: theme.name, mode: theme.mode)))
        try add(PackageFile.css, Data(theme.css.utf8))
        if !theme.js.isEmpty { try add(PackageFile.js, Data(theme.js.utf8)) }
        if !theme.html.isEmpty { try add(PackageFile.html, Data(theme.html.utf8)) }
        for name in imageNames(theme.id) {
            try add(PackageFile.assets + name, try Data(contentsOf: fileURL(theme.id, named: name)))
        }
        guard let data = archive.data else { throw CocoaError(.fileWriteUnknown) }
        return data
    }

    /// 导入主题包（zip 或旧版 JSON 的 .chaiyuetheme）、单独的样式表（.css）或网页装饰层（.html）
    func importFile(_ url: URL) throws -> CustomReaderTheme {
        let data = try Data(contentsOf: url)
        let baseName = url.deletingPathExtension().lastPathComponent
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return try importArchive(data, fallbackName: baseName) }
        if let package = try? JSONDecoder().decode(LegacyPackage.self, from: data) {
            let theme = create(name: package.name, css: package.css, js: package.js)
            try FileManager.default.createDirectory(at: folder(theme.id), withIntermediateDirectories: true)
            for (name, bytes) in package.images {
                try bytes.write(to: fileURL(theme.id, named: name))
            }
            return theme
        }
        guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        if ["html", "htm"].contains(url.pathExtension.lowercased()) {
            return create(name: baseName, css: Self.webTemplateCSS, js: Self.webTemplateJS, mode: .web, html: text)
        }
        return create(name: baseName, css: text, js: "")
    }

    private struct ParsedPackage {
        var name: String
        var css: String
        var js: String
        var mode: ReaderThemeMode
        var html: String
        /// 素材：文件名 → 内容
        var assets: [String: Data]
    }

    private func importArchive(_ data: Data, fallbackName: String) throws -> CustomReaderTheme {
        let package = try parseArchive(data, fallbackName: fallbackName)
        let theme = create(name: package.name, css: package.css, js: package.js, mode: package.mode, html: package.html)
        try writeAssets(package.assets, to: theme.id)
        return theme
    }

    private func writeAssets(_ assets: [String: Data], to id: String) throws {
        try FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true)
        for (name, bytes) in assets { try bytes.write(to: fileURL(id, named: name)) }
    }

    /// 用主题包原地更新一个已有主题（id、名字不变，正在使用的不用重新选）；内容相同时什么都不做，返回 false
    @discardableResult
    func reload(_ id: String, from url: URL) throws -> Bool {
        guard let index = themes.firstIndex(where: { $0.id == id }) else { return false }
        let data = try Data(contentsOf: url)
        guard data.starts(with: [0x50, 0x4B, 0x03, 0x04]) else { throw CocoaError(.fileReadCorruptFile) }
        let package = try parseArchive(data, fallbackName: themes[index].name)
        let old = themes[index]
        let sameAssets = Set(imageNames(id)) == Set(package.assets.keys.map { ($0 as NSString).lastPathComponent })
            && package.assets.allSatisfy { (try? Data(contentsOf: fileURL(id, named: $0.key))) == $0.value }
        if old.css == package.css, old.js == package.js, old.html == package.html, old.mode == package.mode, sameAssets {
            return false
        }
        try? FileManager.default.removeItem(at: folder(id))
        try writeAssets(package.assets, to: id)
        images = images.filter { !$0.key.hasPrefix(id + "/") }
        previews[id] = nil
        var theme = old
        theme.css = package.css
        theme.js = package.js
        theme.html = package.html
        theme.mode = package.mode
        save(theme)
        return true
    }

    /// zip 主题包：认 theme.json / style.css / script.js / page.html，其余文件都当素材（允许整包多套一层文件夹）
    private func parseArchive(_ data: Data, fallbackName: String) throws -> ParsedPackage {
        let archive = try Archive(data: data, accessMode: .read)
        var files: [String: Data] = [:]
        for entry in archive where entry.type == .file {
            let path = entry.path
            if path.hasPrefix("__MACOSX/") || (path as NSString).lastPathComponent.hasPrefix(".") { continue }
            guard entry.uncompressedSize < 40 << 20 else { continue }
            var bytes = Data()
            _ = try archive.extract(entry, skipCRC32: false) { bytes.append($0) }
            files[path] = bytes
        }
        // 整包套了一层文件夹时去掉这层前缀
        let prefix: String = {
            guard let manifest = files.keys.first(where: { ($0 as NSString).lastPathComponent == PackageFile.manifest
                || ($0 as NSString).lastPathComponent == PackageFile.css }) else { return "" }
            let dir = (manifest as NSString).deletingLastPathComponent
            return dir.isEmpty ? "" : dir + "/"
        }()
        func text(_ name: String) -> String? { files[prefix + name].flatMap { String(data: $0, encoding: .utf8) } }
        let manifest = files[prefix + PackageFile.manifest].flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
        guard let css = text(PackageFile.css) ?? (manifest == nil ? nil : "") else { throw CocoaError(.fileReadCorruptFile) }
        let html = text(PackageFile.html) ?? ""
        let mode = manifest?.mode ?? (html.isEmpty ? .native : .web)
        let known: Set<String> = [PackageFile.manifest, PackageFile.css, PackageFile.js, PackageFile.html].map { prefix + $0 }.reduce(into: []) { $0.insert($1) }
        var assets: [String: Data] = [:]
        for (path, bytes) in files where path.hasPrefix(prefix) && !known.contains(path) {
            assets[(path as NSString).lastPathComponent] = bytes
        }
        return ParsedPackage(name: manifest?.name ?? fallbackName, css: css, js: text(PackageFile.js) ?? "",
                             mode: mode, html: html, assets: assets)
    }

    // MARK: - 字体

    /// 按 font-family 列表取第一个能用的字体；`.some(nil)` 表示系统字体，nil 表示都不认识
    static func fontName(for families: [String]) -> String?? {
        for family in families {
            let key = family.lowercased().replacingOccurrences(of: " ", with: "")
            switch key {
            case "宋体", "songti", "songtisc", "stsongti", "stsongti-sc-regular", "serif", "宋":
                return .some(FontLibrary.songti)
            case "楷体", "kaiti", "kaitisc", "stkaiti", "stkaiti-sc-regular", "stkaitisc", "stkaitisc-regular", "楷":
                return .some(FontLibrary.kaiti)
            case "苹方", "pingfang", "pingfangsc", "sans-serif", "system-ui", "-apple-system", "黑体":
                return .some(nil)
            default:
                if let font = FontStore.shared.fonts.first(where: {
                    $0.id.lowercased() == family.lowercased() || $0.name.lowercased() == family.lowercased()
                }) {
                    return .some(font.id)
                }
                if UIFont(name: family, size: 12) != nil { return .some(family) }
                if let name = UIFont.fontNames(forFamilyName: family).first { return .some(name) }
            }
        }
        return nil
    }

    /// 样式里的字体；粗体时取同族粗体
    static func font(_ style: ReaderTextStyle, fallbackName: String?, size: CGFloat, bold: Bool) -> UIFont {
        let name = style.fontFamily.flatMap { fontName(for: $0) } ?? fallbackName
        switch name {
        case FontLibrary.songti?:
            return UIFont(name: bold ? FontLibrary.songtiBold : FontLibrary.songti, size: size) ?? .systemFont(ofSize: size, weight: bold ? .bold : .regular)
        case FontLibrary.kaiti?:
            return UIFont(name: FontLibrary.kaitiName(bold: bold), size: size) ?? .systemFont(ofSize: size, weight: bold ? .bold : .regular)
        case let name?:
            guard let base = UIFont(name: name, size: size) else { return .systemFont(ofSize: size, weight: bold ? .bold : .regular) }
            guard bold else { return base }
            return base.fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: size) } ?? base
        case nil:
            return .systemFont(ofSize: size, weight: bold ? .bold : .regular)
        }
    }

    // MARK: - 模板

    static let templateCSS = """
    /* 柴阅阅读主题 · 样式表
       选择器：body / p 正文，.chap-no 章序号，.chap-title 章名，
       .header 页眉，.footer 页脚，.page 纸面，p.类名 由脚本分类的段落。
       单位：px、em（相对正文字号）、%；颜色：#rgb、#rrggbb、rgb()、rgba()。
       深色外观写在 @media (prefers-color-scheme: dark) 里。 */

    :root {
      --ink: #2c2721;
      --paper: #f2ebdd;
    }

    .page {
      background-color: var(--paper);
      padding: 30px 26px 25px;   /* 上：页眉到正文，左右：边距，下：正文到页脚 */
      --grain: .55;              /* 纸张颗粒 0–1 */
    }

    body {
      font-family: "Songti SC", serif;
      color: var(--ink);
      line-height: 1.9;
      letter-spacing: 0;
    }

    p {
      text-indent: 2em;
      margin-bottom: .5em;
      text-align: justify;
    }

    .chap-no {
      font-size: .68em;
      color: rgba(44, 39, 33, .45);
      letter-spacing: .15em;
      margin: 11px 0 10px;
    }

    .chap-title {
      font-size: 1.4em;
      font-weight: 700;
      letter-spacing: 1.5px;
      margin-bottom: 34px;
    }

    .header, .footer {
      font-size: 11px;
      color: rgba(44, 39, 33, .45);
    }

    /* 脚本把对话段落标成 dialog 时生效 */
    p.dialog {
      color: #5b4a3a;
    }

    @media (prefers-color-scheme: dark) {
      :root { --ink: #8e8a84; --paper: #0e0e0f; }
      .page { --grain: 0; }
      .chap-no, .header, .footer { color: rgba(142, 138, 132, .45); }
      p.dialog { color: #a89c8c; }
    }
    """

    static let templateJS = """
    // 柴阅阅读主题 · 脚本（可删除，不写就用默认页眉页脚）
    // ctx：book 书名、author、chapter 章名、chapterIndex、chapterCount、
    //      page 本章第几页（从 1 起）、pages 本章页数、percent 全书进度、time 时间、battery 电量（-1 未知）
    // 返回字符串，或 { left, center, right }；返回 null 用默认内容。

    function header(ctx) {
      return ctx.page === 1 ? ctx.book : ctx.chapter;
    }

    function footer(ctx) {
      return { left: ctx.page + ' / ' + ctx.pages, right: ctx.time + '  ' + ctx.percent.toFixed(1) + '%' };
    }

    // 给段落分类，返回的名字对应样式表里的 p.名字
    function paragraphClass(text, index) {
      return /^[“「"]/.test(text) ? 'dialog' : null;
    }
    """

    // MARK: - 网页模式模板

    static let webTemplateCSS = """
    /* 柴阅阅读主题 · 网页模式
       整页由 WebKit 渲染，完整 CSS 都能用：渐变、阴影、伪元素、动画、@font-face、滤镜……
       结构：
         .page            纸面（铺满屏幕）
           #decor         装饰层，内容来自「HTML」页
           .header        页眉（.left .center .right）
           #viewport      正文区，正文按页分栏
             #chapter
               .chap-head > .chap-no + .chap-title
               p[data-i]  段落（脚本 paragraphClass 可加类名）
               figure     插图
           .footer        页脚
       .page 的 padding 依次是：页眉到正文、右边距、正文到页脚、左边距（不含刘海与 Home 条）。
       可用变量：--reader-font-size、--reader-font、--reader-paper、--reader-ink、
                 --reader-secondary、--progress（0–1 全书进度）、--chapter-progress（0–1 本章）、
                 --battery（0–1）、--safe-top / --safe-bottom（刘海与 Home 条）、
                 --text-top / --text-bottom（正文区上下边）。
       .page 上还会随翻页切换 .first-page / .last-page 两个类名。
       素材：在「素材」页添加，用 url(文件名) 引用；字体文件可配合 @font-face 使用。 */

    :root {
      --ink: #2b2620;
      --paper: #f3ecdf;
      --accent: #a0522d;
    }

    .page {
      background:
        radial-gradient(120% 80% at 50% 0%, rgba(255,255,255,.55), transparent 60%),
        linear-gradient(#f5efe3, var(--paper));
      color: var(--ink);
      padding: 34px 28px 26px;
    }

    body {
      font-family: "Songti SC", serif;
      line-height: 1.9;
    }

    p {
      text-indent: 2em;
      margin: 0 0 .55em;
      text-align: justify;
    }

    .chap-head {
      text-align: center;
      margin-bottom: 2.2em;
    }

    .chap-no {
      color: var(--accent);
      letter-spacing: .4em;
      font-size: .7em;
      margin: .4em 0 .9em;
    }

    .chap-title {
      font-size: 1.45em;
      letter-spacing: .08em;
      margin: 0;
    }

    /* 章名下的小装饰 */
    .chap-title::after {
      content: "";
      display: block;
      width: 36px;
      height: 2px;
      margin: .9em auto 0;
      border-radius: 1px;
      background: linear-gradient(90deg, transparent, var(--accent), transparent);
    }

    /* 章首段首字下沉 */
    .chap-head + p::first-letter {
      float: left;
      font-size: 2.7em;
      line-height: 1;
      margin: .06em .12em 0 -.1em;
      color: var(--accent);
    }

    .chap-head + p { text-indent: 0; }

    p.dialog { color: #5a4636; }

    .header, .footer {
      font-size: 11px;
      letter-spacing: .5px;
      color: rgba(43, 38, 32, .45);
    }

    /* 页码条：按住拖动跳页，刻度是本章真实页数；圆点停在当前页（--page-pos：第一页 0、最后一页 1） */
    #decor .pager {
      position: absolute;
      left: 26px; right: 26px;
      bottom: calc(var(--safe-bottom) + 24px);
      height: 2px;
      border-radius: 1px;
      background: rgba(160, 82, 45, .14);
    }
    #decor .pager .ticks i {
      width: 2px; height: 2px; margin: -1px 0 0 -1px;
      border-radius: 50%; background: rgba(160, 82, 45, .35);
    }
    #decor .pager .ticks i.read { background: var(--accent); }
    #decor .pager .knob {
      position: absolute;
      left: -5px; top: -4px;
      width: 10px; height: 10px;
      border-radius: 50%;
      background: var(--accent);
      translate: calc(100cqw * var(--page-pos, 0)) 0;
      transition: scale .2s;
    }
    .page.scrubbing #decor .pager .knob { scale: 1.5; }

    #decor .corner {
      position: absolute;
      top: 14px; right: 18px;
      width: 46px; height: 46px;
      border-top: 1px solid rgba(160, 82, 45, .25);
      border-right: 1px solid rgba(160, 82, 45, .25);
      border-top-right-radius: 14px;
    }

    @media (prefers-color-scheme: dark) {
      :root { --ink: #a39d94; --paper: #121110; --accent: #c98a5e; }
      .page { background: linear-gradient(#171513, var(--paper)); }
      p.dialog { color: #b9ab98; }
      .header, .footer { color: rgba(163, 157, 148, .45); }
    }
    """

    static let webTemplateJS = """
    // 柴阅阅读主题 · 网页模式脚本（运行在阅读页里，不能联网）
    // 与原生模式相同的三个钩子：header(ctx) / footer(ctx) / paragraphClass(text, index)
    // 另外每次翻页会在 document 上派发 'readerpage' 事件，event.detail 就是 ctx，
    // 装饰层可以据此做动画；reader.ctx 随时能读到当前的 ctx。
    // chapterReady(el, info) 在每章正文插入后、分页前调用，可往 el 里加贴纸等元素（别插进 p 段落里）。

    function header(ctx) {
      return { left: ctx.page === 1 ? ctx.book : ctx.chapter, right: ctx.time };
    }

    function footer(ctx) {
      return { left: ctx.page + ' / ' + ctx.pages, right: ctx.percent.toFixed(1) + '%' };
    }

    function paragraphClass(text, index) {
      return /^[“「"]/.test(text) ? 'dialog' : null;
    }

    document.addEventListener('readerpage', function (e) {
      // 例：每章最后一页给纸面加个类名，样式表里写 .page.last { … }
      document.querySelector('.page').classList.toggle('last', e.detail.page === e.detail.pages);
    });
    """

    static let webTemplateHTML = """
    <!-- 装饰层：放在纸面最底下、正文之下，不挡点按与翻页 -->
    <div class="corner"></div>
    <!-- 页码条：data-scrub 让它可以拖动跳页，data-scrub-ticks 里由阅读器按本章页数生成刻度 -->
    <div class="pager" data-scrub><div class="ticks" data-scrub-ticks></div><i class="knob"></i></div>
    """
}
#endif  // #if canImport(UIKit)
