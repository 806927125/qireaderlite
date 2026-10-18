import Foundation

/// 阅读会话：把「界面 ↔ 引擎 ↔ 阅读进度」三件事的接线收在一处。
///
/// 为什么要单独一个类：SwiftUI 的 View 是 struct，**不能被 [weak self] 捕获**
/// （C 里就是在这儿编译失败的）。而且闭包被 ReaderHost（类）长期持有，
/// 直接捕获 View 会连带把 @State 绑定一起拖住 —— 收进类里最干净。
@MainActor
final class ReaderSession: ObservableObject {
    let host = ReaderHost()
    let book: Book
    let flat: [Chapter]
    /// SwiftUI 的 EnvironmentObject 在 init 里拿不到，.task 里再挂进来
    private var sources: SourceStore?
    private var library: LibraryStore?
    /// 正文被点了一下（宿主用它显/隐工具栏）
    var onTap: (() -> Void)?

    @Published var index: Int = 0
    @Published var errorText: String = ""
    @Published var hostReady = false

    init(book: Book, chapters: [Chapter], start: Chapter) {
        self.book = book
        self.flat = chapters.filter { !$0.isVolume }

        let startIdx = self.flat.firstIndex(where: { $0.url == start.url }) ?? 0
        self.index = max(0, min(startIdx, max(self.flat.count - 1, 0)))

        wire()
    }

    var current: Chapter? {
        flat.indices.contains(index) ? flat[index] : flat.first
    }

    private func wire() {
        host.onReady = { [weak self] in self?.hostReady = true }

        host.onRequestChapter = { [weak self] i in
            await self?.load(index: i)
        }

        host.onProgress = { [weak self] i, ratio in
            guard let self, self.flat.indices.contains(i) else { return }
            self.index = i
            self.library?.saveProgress(bookID: self.book.id,
                                      chapterIndex: i,
                                      ratio: ratio,
                                      chapterTitle: self.flat[i].title)
        }

        host.onVisibleChapter = { [weak self] i in
            guard let self, self.flat.indices.contains(i) else { return }
            self.index = i
        }

        host.onTap = { [weak self] in
            guard let self, let cb = self.onTap else { return }
            cb()
        }

        host.onDebugLog = { [weak self] ev, payload in
            guard let self, self.errorText.isEmpty else { return }
            if ev.contains("error") || ev.contains("fail") {
                self.errorText = String(describing: payload["error"] ?? ev)
            }
        }
    }

    /// 界面 ready 之后：喂设置 + 初始章节，然后拉当前章
    func attach(sources: SourceStore, library: LibraryStore) {
        self.sources = sources
        self.library = library
    }

    func start(settings: [String: Any]) async {
        for _ in 0..<60 where !hostReady {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        host.setSettings(settings)
        host.apply(chapters: flat, at: index, progress: library?.progress(bookID: book.id))
        await load(index: index)
    }

    func jump(to i: Int) {
        guard flat.indices.contains(i) else { return }
        index = i
        host.apply(chapters: flat, at: i, progress: nil)
        Task { await load(index: i) }
    }

    func load(index i: Int) async {
        guard flat.indices.contains(i),
              let s = sources?.source(id: book.origin) else { return }
        let ch = flat[i]
        do {
            let dto = try await SourceService.shared.content(source: s, chapter: ch)
            host.update(index: i, text: dto.content,
                        title: dto.title.isEmpty ? ch.title : dto.title)
            errorText = ""
        } catch {
            host.fail(index: i, message: error.localizedDescription)
            errorText = error.localizedDescription
        }
    }
}
