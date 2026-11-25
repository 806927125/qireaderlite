import Foundation
import ChaiyueModels
import ChaiyueEngine

/// 封面与正文插图的下载和磁盘缓存。返回原始图片数据，解码交给界面层；同一地址的并发请求只下载一次
public actor ImageCache {
    private let directory: URL
    private let environment: SourceEnvironment
    private var inflight: [String: Task<Data, Error>] = [:]

    public init(directory: URL, environment: SourceEnvironment) {
        self.directory = directory
        self.environment = environment
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// `source` 为图片所属书源（使用其请求头、Cookie 与解密脚本）；为空时按普通网址下载。
    /// `isContent` 为 true 时是正文插图（用正文规则的 imageDecode 解密），否则是封面（coverDecodeJs）。
    /// 地址支持 Legado 的 `url,{"headers":…}` 写法与 data URL
    public func data(for url: String, source: BookSource?, isContent: Bool = false) async throws -> Data {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { throw URLError(.badURL) }
        let isDataURL = url.hasPrefix("data:")
        // 内嵌图片（段评气泡、神评论卡片多为 data:image/svg+xml）直接解码，不经网络与解密脚本
        if isDataURL, let data = InlineImage.dataURLContent(url), !data.isEmpty { return data }
        let key = cacheKey(url, source: source, isContent: isContent)
        let file = directory.appendingPathComponent(key)
        if !isDataURL, let cached = try? Data(contentsOf: file), !cached.isEmpty {
            return cached
        }
        if let task = inflight[key] {
            return try await task.value
        }
        let webBook = WebBook(source: source ?? Self.placeholderSource(for: url), environment: environment)
        let task = Task { try await webBook.fetchImage(url, isContent: isContent) }
        inflight[key] = task
        defer { inflight[key] = nil }
        let data = try await task.value
        guard !data.isEmpty else { throw URLError(.zeroByteResource) }
        if !isDataURL {
            try? data.write(to: file, options: .atomic)
        }
        return data
    }

    /// 只读磁盘缓存，不联网；可在任意线程同步调用
    public nonisolated func cachedData(for url: String, source: BookSource?, isContent: Bool = false) -> Data? {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        if url.hasPrefix("data:") { return InlineImage.dataURLContent(url).flatMap { $0.isEmpty ? nil : $0 } }
        let file = directory.appendingPathComponent(cacheKey(url, source: source, isContent: isContent))
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        return data
    }

    /// 封面沿用原有的键；正文插图解密方式不同，另加标记
    private nonisolated func cacheKey(_ url: String, source: BookSource?, isContent: Bool) -> String {
        Hashing.md5((source?.bookSourceUrl ?? "") + "\u{1}" + url + (isContent ? "\u{1}content" : ""))
    }

    public func totalSize() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    public func clear() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 没有书源时用图片所在站点构造一个空书源，Cookie 按该站点保存
    static func placeholderSource(for url: String) -> BookSource {
        let address = url.components(separatedBy: ",{").first ?? url
        let origin = URL(string: address).flatMap { url -> String? in
            guard let scheme = url.scheme, let host = url.host else { return nil }
            return "\(scheme)://\(host)"
        } ?? "image"
        return BookSource(bookSourceUrl: origin, bookSourceName: "")
    }
}
