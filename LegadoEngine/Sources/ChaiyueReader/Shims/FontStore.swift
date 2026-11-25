#if canImport(SwiftUI)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Design/FontStore.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Design/FontStore.swift

import CoreText
import Foundation
import Observation
import UniformTypeIdentifiers
import ZIPFoundation

@Observable
final class FontStore {
    static let shared = FontStore()

    nonisolated static let extensions: Set<String> = ["ttf", "otf", "ttc", "otc", "woff", "woff2", "dfont"]
    static let importTypes: [UTType] = [.font, .zip] + ["ttc", "otc", "woff", "woff2", "dfont"].compactMap { UTType(filenameExtension: $0) }

    private(set) var fonts: [ImportedFont] = []
    /// 字体增删后递增，排版据此重排
    private(set) var version = 0

    nonisolated private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Fonts", directoryHint: .isDirectory)
    }

    private init() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        var loaded: [ImportedFont] = []
        for url in files where Self.extensions.contains(url.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            loaded += Self.faces(in: url)
        }
        fonts = loaded.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func font(_ id: String?) -> ImportedFont? {
        guard let id else { return nil }
        return fonts.first { $0.id == id }
    }

    /// 导入字体文件或 zip，返回新增的字面
    func importFiles(_ urls: [URL]) async throws -> [ImportedFont] {
        let known = Set(fonts.map(\.id))
        let added = try await Task.detached(priority: .userInitiated) {
            try Self.copyIn(urls, known: known)
        }.value
        guard !added.isEmpty else { return [] }
        fonts = (fonts + added).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        version += 1
        return added
    }

    /// 删掉字体所在的文件（同一文件里的其他字面一起删）
    func remove(_ font: ImportedFont) {
        let url = Self.directory.appending(path: font.file)
        CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
        try? FileManager.default.removeItem(at: url)
        fonts.removeAll { $0.file == font.file }
        version += 1
    }

    enum ImportError: LocalizedError {
        case unsupported

        var errorDescription: String? { "没有找到可用的字体文件" }
    }

    nonisolated private static func copyIn(_ urls: [URL], known: Set<String>) throws -> [ImportedFont] {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let scratch = manager.temporaryDirectory.appending(path: "font-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: scratch) }

        var candidates: [URL] = []
        var foundAny = false
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if url.pathExtension.lowercased() == "zip" {
                candidates += try unzipFonts(url, into: scratch)
            } else {
                let copy = scratch.appending(path: "\(UUID().uuidString).\(url.pathExtension.lowercased())")
                try manager.copyItem(at: url, to: copy)
                candidates.append(copy)
            }
        }

        var seen = known
        var added: [ImportedFont] = []
        for file in candidates {
            let faces = Self.faces(in: file)
            guard !faces.isEmpty else { continue }
            foundAny = true
            guard faces.contains(where: { !seen.contains($0.id) }) else { continue }
            let name = "\(UUID().uuidString).\(file.pathExtension.lowercased())"
            let target = directory.appending(path: name)
            try manager.moveItem(at: file, to: target)
            guard CTFontManagerRegisterFontsForURL(target as CFURL, .process, nil) else {
                try? manager.removeItem(at: target)
                continue
            }
            let placed = faces.map { ImportedFont(id: $0.id, name: $0.name, file: name) }
            added += placed
            seen.formUnion(placed.map(\.id))
        }
        if !foundAny { throw ImportError.unsupported }
        return added
    }

    nonisolated private static func unzipFonts(_ url: URL, into scratch: URL) throws -> [URL] {
        let archive = try Archive(url: url, accessMode: .read)
        var result: [URL] = []
        for entry in archive where entry.type == .file {
            let path = entry.path
            let leaf = (path as NSString).lastPathComponent
            let ext = (leaf as NSString).pathExtension.lowercased()
            // 跳过 macOS 压缩时带上的资源分叉
            guard extensions.contains(ext), !path.hasPrefix("__MACOSX"), !leaf.hasPrefix("._") else { continue }
            let target = scratch.appending(path: "\(UUID().uuidString).\(ext)")
            _ = try archive.extract(entry, to: target)
            result.append(target)
        }
        return result
    }

    nonisolated private static func faces(in url: URL) -> [ImportedFont] {
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
        return descriptors.compactMap { descriptor in
            guard let id = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String else { return nil }
            let display = CTFontDescriptorCopyLocalizedAttribute(descriptor, kCTFontDisplayNameAttribute, nil) as? String
            return ImportedFont(id: id, name: display ?? id, file: url.lastPathComponent)
        }
    }
}
#endif
