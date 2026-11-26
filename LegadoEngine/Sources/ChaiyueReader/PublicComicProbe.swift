#if os(iOS)
// ⭐⭐⭐⭐⭐ **漫画取图的【自检探针】**（2026-11-26 · 真机「图片出不来」）⭐⭐⭐⭐⭐
//
// ⚠️⚠️⚠️ **为什么需要**（真机实证）⭐⭐⭐⚠️：
//   真机症状：漫画页打开了、页码显示「1 / 2」（⇒ 目录/正文/抽地址这条链是通的），
//   但**图一直转圈、而且没有任何错误提示** ⇒ 用户只能干瞪眼 ⇒ 我只能靠猜 ⭐⭐⭐
//   ⇒ 根因在柴阅：`ComicImageStore.start(...)` 里是 **`catch {}`** ⇒ **取图的错误被完全吞掉** ⭐⭐⭐
//   ⇒ 所以：**App 必须自己拿到「失败原因」**，才能说人话（而不是「图片加载失败」）⭐⭐⭐
//
// ⭐⭐⭐ **设计**（不碰柴阅一行逻辑，只加一个 public 出口）⭐⭐⭐：
//   · 宿主调 `ChaiyueComicProbe.probe(library:book:)` ⇒ 返回 **nil = 一切正常**，
//     或 **一句人话**（HTTP 403 / 超时 / 无效 URL / 本章没有图片 …）⭐⭐⭐
//   · 探针走的是**与漫画页完全同一条链**（同一个 `MediaSession`、同一个 `service.imageData`）
//     ⇒ ⇒ 探针失败 = 漫画页会失败 ⇒ 结论可信 ⭐⭐⭐
//   · ⚠️ **不做第二次网络请求**：复用 `MediaSession` 里的目录缓存与图片缓存 ⭐⭐⭐
import ChaiyueModels
import ChaiyueReaderServices

/// 漫画取图自检：给宿主一句「为什么图出不来」
public enum ChaiyueComicProbe {
    /// 自检结果
    public struct Result {
        /// nil = 取图链路完全正常
        public var failure: String?
        /// 实际取到的图片地址（便于宿主/日志定位）
        public var sampleURL: String?
        /// 取到的图片字节数（0 = 空）
        public var byteCount: Int
    }

    /// 自检：拿这本书第一章的第一张图，按**漫画页同一条链**取一次
    ///
    /// - Returns: `failure == nil` 表示一切正常；否则是**一句能直接说给用户听**的原因 ⭐⭐⭐
    @MainActor
    public static func probe(library: ChaiyueReaderLibrary, book: Book) async -> Result {
        let session = library.mediaSession(for: book)
        // ① 目录（命中宿主预写的章节缓存 ⇒ 不额外请求站方）⭐⭐⭐
        await session.open()
        guard !session.chapters.isEmpty else {
            return Result(failure: "这本书还没有章节（目录是空的）", sampleURL: nil, byteCount: 0)
        }
        let index = 0
        // ② 本章的图片地址（从正文里抽；抽不到就是「本章不是漫画」）
        let sources: [String]
        do {
            sources = try await session.images(at: index)
        } catch {
            return Result(failure: "取本章正文失败：\(error.localizedDescription)", sampleURL: nil, byteCount: 0)
        }
        guard let src = sources.first else {
            return Result(failure: "本章没有图片（正文里抽不到图片地址）", sampleURL: nil, byteCount: 0)
        }
        // ③ 取图（与漫画页 `ComicModel` 走的是同一个 `MediaSession.imageData`）⭐⭐⭐
        do {
            let data = try await session.imageData(src, chapter: index)
            if data.isEmpty {
                return Result(failure: "图片下载回来是空的（0 字节）", sampleURL: src, byteCount: 0)
            }
            return Result(failure: nil, sampleURL: src, byteCount: data.count)
        } catch {
            return Result(failure: "图片下载失败：\(error.localizedDescription)", sampleURL: src, byteCount: 0)
        }
    }
}
#endif  // #if os(iOS)
