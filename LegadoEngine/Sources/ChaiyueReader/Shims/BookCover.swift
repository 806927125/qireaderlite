#if canImport(UIKit)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Design/BookCover.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Design/BookCover.swift

import ChaiyueModels
import SwiftUI

struct BookCover: View {
    let title: String
    let author: String
    let url: String?
    let book: Book?
    var maxPixel: CGFloat = 360
    var radius: CGFloat = Metrics.coverRadius
    var onPalette: (([Color]) -> Void)?

    @Environment(AppModel.self) private var app
    @State private var image: UIImage?

    init(title: String, author: String, url: String?, book: Book?, maxPixel: CGFloat = 360,
         radius: CGFloat = Metrics.coverRadius, onPalette: (([Color]) -> Void)? = nil) {
        self.title = title.withoutEmoji
        self.author = author.withoutEmoji
        self.url = url.flatMap { $0.isEmpty ? nil : $0 }
        self.book = book
        self.maxPixel = maxPixel
        self.radius = radius
        self.onPalette = onPalette
        _image = State(initialValue: self.url.flatMap { ImagePipeline.shared.cached($0) })
    }

    init(book: Book, maxPixel: CGFloat = 360, onPalette: (([Color]) -> Void)? = nil) {
        self.init(title: book.name, author: book.author, url: book.displayCover, book: book, maxPixel: maxPixel, onPalette: onPalette)
    }

    init(search: SearchBook, maxPixel: CGFloat = 360) {
        self.init(title: search.name, author: search.author, url: search.coverUrl, book: search.toBook(), maxPixel: maxPixel)
    }

    var design: CoverDesign { CoverDesign(seed: title + "\u{1}" + author) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Color.clear
            .aspectRatio(120.0 / 172.0, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    GeneratedCover(design: design, title: title, author: author)
                }
            }
            .overlay { SpineLight() }
            .overlay { GrainOverlay(opacity: 0.22) }
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else {
            onPalette?(design.palette.heroColors)
            return
        }
        if let image {
            onPalette?(await ImagePipeline.shared.palette(for: url, image: image))
            return
        }
        onPalette?(design.palette.heroColors)
        guard let loaded = await ImagePipeline.shared.image(for: url, book: book, app: app, maxPixel: maxPixel) else { return }
        withAnimation(.easeOut(duration: 0.3)) { image = loaded }
        onPalette?(await ImagePipeline.shared.palette(for: url, image: loaded))
    }
}

struct SpineLight: View {
    var body: some View {
        ZStack {
            LinearGradient(stops: [
                .init(color: .black.opacity(0.3), location: 0),
                .init(color: .white.opacity(0.16), location: 0.024),
                .init(color: .black.opacity(0.14), location: 0.046),
                .init(color: .clear, location: 0.09),
            ], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.white.opacity(0.1), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.34))
        }
        .allowsHitTesting(false)
    }
}
#endif
