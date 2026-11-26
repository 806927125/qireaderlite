#if os(iOS)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Media/Comic/ComicModel.swift 搬运**（2026-11-26 · 柴阅漫画阅读器 vendor）⭐⭐⭐⭐⭐
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Media/Comic/ComicModel.swift
//
// ⚠️⚠️ **与上游的 diff**（只有这些，其余一字未改）⭐⭐⭐：
//   ① `import ReaderModels` → `import ChaiyueModels`、`import ReaderServices` → `import ChaiyueReaderServices`
//      （模块改名，与本仓库其它 vendor 文件一致）⭐⭐⭐
//   ② 整文件包进 `#if os(iOS)`（漫画阅读器用满 UIKit ⇒ macOS/Linux 编不到 ⇒ 与本仓库其它 iOS 界面件一致）⭐⭐⭐
//   ③ `MediaKindStyle.swift` 里 `BookMediaKind` 的三个成员升 public（宿主要用「漫画」角标与「开始看漫画」文案）⭐⭐⭐
import ImageIO
import ChaiyueModels
import ChaiyueReaderServices
import SwiftUI
import UIKit

/// 一张图在书里的位置：第几章的第几张
nonisolated struct ComicPage: Hashable, Sendable {
    var chapter: Int
    var page: Int
}

enum ComicMode: String {
    case strip, pager
}

enum ComicChapter {
    case loading
    case failed(String)
    case ready([String])
}

/// 漫画阅读状态：各章图片列表、当前图、模式与菜单。阅读视图（UIKit）通过回调接收章节与图片的变化
@Observable
final class ComicModel {
    let session: MediaSession
    private(set) var chapters: [Int: ComicChapter] = [:]
    private(set) var current = ComicPage(chapter: 0, page: 0)
    /// 换章、刷新后递增，阅读视图按它重建
    private(set) var generation = 0
    var mode: ComicMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }
    var menuVisible = false

    @ObservationIgnored let images: ComicImageStore
    @ObservationIgnored var onChapterChange: ((Int) -> Void)?
    @ObservationIgnored var onSeek: ((ComicPage) -> Void)?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private static let modeKey = "comic.mode"

    init(session: MediaSession) {
        self.session = session
        images = ComicImageStore(session: session)
        mode = UserDefaults.standard.string(forKey: Self.modeKey).flatMap(ComicMode.init(rawValue:)) ?? .strip
    }

    var book: Book { session.book }

    /// 当前章已就绪，可以显示阅读视图
    var isReady: Bool {
        guard generation > 0, case .ready = chapters[current.chapter] else { return false }
        return true
    }

    func start() async {
        if session.chapters.isEmpty || session.tocState != .ready { await session.open() }
        guard session.tocState == .ready, !session.chapters.isEmpty else { return }
        current = ComicPage(chapter: session.index, page: session.position)
        await load(current.chapter)
        clampCurrent()
        generation += 1
    }

    func retryToc() async {
        await session.refreshToc()
        guard session.tocState == .ready, !session.chapters.isEmpty else { return }
        current = ComicPage(chapter: session.index, page: session.position)
        await load(current.chapter, retry: true)
        clampCurrent()
        generation += 1
    }

    // MARK: - 章节

    func sources(_ chapter: Int) -> [String]? {
        guard case .ready(let list) = chapters[chapter] else { return nil }
        return list
    }

    func source(_ page: ComicPage) -> String? {
        guard let list = sources(page.chapter), list.indices.contains(page.page) else { return nil }
        return list[page.page]
    }

    func pageCount(_ chapter: Int) -> Int? { sources(chapter)?.count }

    func title(_ chapter: Int) -> String {
        session.chapters.indices.contains(chapter) ? session.chapters[chapter].title.withoutEmoji : ""
    }

    /// 前后相邻的正文章（跳过卷名）
    func neighbor(_ chapter: Int, _ step: Int) -> Int? {
        var index = chapter + step
        while session.chapters.indices.contains(index) {
            if !session.chapters[index].isVolume { return index }
            index += step
        }
        return nil
    }

    /// 只在没取过时加载；失败过的不自动重试（书源匿名额度有限）
    func request(_ chapter: Int) {
        guard session.chapters.indices.contains(chapter), chapters[chapter] == nil else { return }
        Task { await load(chapter) }
    }

    func retry(_ chapter: Int) {
        Task { await load(chapter, retry: true) }
    }

    func load(_ chapter: Int, retry: Bool = false, refresh: Bool = false) async {
        guard session.chapters.indices.contains(chapter) else { return }
        switch chapters[chapter] {
        case .loading: return
        case .ready where !refresh: return
        case .failed where !retry && !refresh: return
        default: break
        }
        chapters[chapter] = .loading
        onChapterChange?(chapter)
        do {
            let list = try await session.images(at: chapter, refresh: refresh)
            chapters[chapter] = .ready(list)
        } catch {
            chapters[chapter] = .failed(error.localizedDescription)
        }
        onChapterChange?(chapter)
    }

    // MARK: - 跳转

    func jump(chapter: Int, page: Int = 0) {
        guard session.chapters.indices.contains(chapter) else { return }
        if chapter == current.chapter, isReady {
            seek(page)
            return
        }
        current = ComicPage(chapter: chapter, page: max(0, page))
        commit()
        Task {
            await load(chapter, retry: true)
            guard current.chapter == chapter, sources(chapter) != nil else { return }
            clampCurrent()
            generation += 1
        }
    }

    /// 本章内跳到第 `page` 张
    func seek(_ page: Int) {
        guard let count = pageCount(current.chapter), count > 0 else { return }
        onSeek?(ComicPage(chapter: current.chapter, page: min(max(0, page), count - 1)))
    }

    func refreshCurrent() {
        let chapter = current.chapter
        Task {
            images.forget(chapter: chapter)
            await load(chapter, refresh: true)
            guard current.chapter == chapter else { return }
            clampCurrent()
            generation += 1
        }
    }

    /// 重建阅读视图（切换模式）
    func rebuild() {
        generation += 1
    }

    private func clampCurrent() {
        guard let count = pageCount(current.chapter) else { return }
        current.page = min(max(0, current.page), max(0, count - 1))
    }

    // MARK: - 进度

    func didView(_ page: ComicPage) {
        guard page != current else { return }
        let changed = page.chapter != current.chapter
        current = page
        saveTask?.cancel()
        if changed {
            commit()
            return
        }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.commit()
        }
    }

    func commit() {
        saveTask?.cancel()
        saveTask = nil
        session.update(index: current.chapter, position: current.page, length: pageCount(current.chapter))
    }

    func close() {
        if isReady { commit() }
        images.cancelAll()
        onChapterChange = nil
        onSeek = nil
    }
}

// MARK: - 图片

/// 按优先级排队取图：最多 3 张同时进行，后台降采样解码，内存按字节数限额
final class ComicImageStore {
    private let session: MediaSession
    private let cache = NSCache<NSString, UIImage>()
    private var cachedKeys: Set<ComicPage> = []
    /// 图片高宽比，图片被内存回收后仍保留，版面不会变回占位比例
    private var aspects: [ComicPage: CGFloat] = [:]
    private var failures: Set<ComicPage> = []
    private var tasks: [ComicPage: Task<Void, Never>] = [:]
    private var queue: [(ComicPage, String)] = []
    private let limit = 3

    /// 解码目标宽度（像素）
    var pixelWidth: CGFloat = 1290
    var onUpdate: ((ComicPage) -> Void)?

    init(session: MediaSession) {
        self.session = session
        cache.totalCostLimit = 180 * 1024 * 1024
    }

    func image(_ page: ComicPage) -> UIImage? {
        cache.object(forKey: Self.key(page))
    }

    func aspect(_ page: ComicPage) -> CGFloat? { aspects[page] }
    func failed(_ page: ComicPage) -> Bool { failures.contains(page) }

    /// 替换等待队列：按传入顺序取，已在进行的不受影响
    func want(_ list: [(ComicPage, String)]) {
        queue = list.filter { page, _ in tasks[page] == nil && !failures.contains(page) && image(page) == nil }
        pump()
    }

    func retry(_ page: ComicPage, src: String) {
        failures.remove(page)
        queue.removeAll { $0.0 == page }
        queue.insert((page, src), at: 0)
        onUpdate?(page)
        pump()
    }

    func forget(chapter: Int) {
        for page in cachedKeys where page.chapter == chapter { cache.removeObject(forKey: Self.key(page)) }
        cachedKeys = cachedKeys.filter { $0.chapter != chapter }
        aspects = aspects.filter { $0.key.chapter != chapter }
        failures = failures.filter { $0.chapter != chapter }
        for (page, task) in tasks where page.chapter == chapter { task.cancel() }
        queue.removeAll { $0.0.chapter == chapter }
    }

    func cancelAll() {
        queue.removeAll()
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        onUpdate = nil
    }

    private func pump() {
        while tasks.count < limit, !queue.isEmpty {
            let (page, src) = queue.removeFirst()
            guard tasks[page] == nil, image(page) == nil else { continue }
            start(page, src: src)
        }
    }

    private func start(_ page: ComicPage, src: String) {
        let width = pixelWidth
        let session = session
        tasks[page] = Task { [weak self] in
            var image: UIImage?
            do {
                let data = try await session.imageData(src, chapter: page.chapter)
                image = await Task.detached(priority: .userInitiated) { ComicDecoder.decode(data, pixelWidth: width) }.value
            } catch {}
            self?.finish(page, image: image, cancelled: Task.isCancelled)
        }
    }

    private func finish(_ page: ComicPage, image: UIImage?, cancelled: Bool) {
        tasks[page] = nil
        guard !cancelled else {
            pump()
            return
        }
        if let image, image.size.width > 0 {
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            cache.setObject(image, forKey: Self.key(page), cost: cost)
            cachedKeys.insert(page)
            aspects[page] = image.size.height / image.size.width
        } else {
            failures.insert(page)
        }
        onUpdate?(page)
        pump()
    }

    private static func key(_ page: ComicPage) -> NSString {
        "\(page.chapter)#\(page.page)" as NSString
    }
}

nonisolated enum ComicDecoder {
    /// 缩到目标宽度并立即解码；超长条图再按总像素限一次，避免单张图占用几百兆内存
    static func decode(_ data: Data, pixelWidth: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return UIImage(data: data)?.preparingForDisplay()
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        guard width > 0, height > 0 else { return UIImage(data: data)?.preparingForDisplay() }
        var scale = min(1, Double(pixelWidth) / width)
        let maxPixels = 24_000_000.0
        if width * height * scale * scale > maxPixels { scale = (maxPixels / (width * height)).squareRoot() }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, (max(width, height) * scale).rounded()),
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return UIImage(data: data)?.preparingForDisplay()
        }
        return UIImage(cgImage: image)
    }
}

#endif  // #if os(iOS)
