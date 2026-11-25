#if canImport(UIKit)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Design/Images.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Design/Images.swift

import CoreImage
import ImageIO
import ChaiyueModels
import SwiftUI
import UIKit

final class ImagePipeline {
    static let shared = ImagePipeline()

    private let images = NSCache<NSString, UIImage>()
    private let palettes = NSCache<NSString, PaletteBox>()
    private var failures: Set<String> = []

    private init() {
        images.countLimit = 300
    }

    func cached(_ key: String) -> UIImage? {
        images.object(forKey: key as NSString)
    }

    func hasFailed(_ key: String) -> Bool { failures.contains(key) }

    /// 清除磁盘缓存后调用：失败记录一并清掉，之后可以重新下载
    func clearMemory() {
        images.removeAllObjects()
        failures.removeAll()
        SVGRasterizer.shared.clear()
    }

    /// SVG 按最长边 `maxPixel` 像素光栅化
    private static func rasterize(_ svg: SVGImage, maxPixel: CGFloat) async -> UIImage? {
        let scale = UIScreen.main.scale
        let longest = max(svg.intrinsicSize.width, svg.intrinsicSize.height)
        let width = svg.intrinsicSize.width * min(1, maxPixel / scale / max(1, longest))
        let size = svg.displaySize(maxWidth: width, full: true)
        if let cached = SVGRasterizer.shared.cached(svg, size: size) { return cached }
        return await withCheckedContinuation { continuation in
            SVGRasterizer.shared.render(svg, size: size) { continuation.resume(returning: $0) }
        }
    }

    func image(for url: String, book: Book?, app: AppModel, maxPixel: CGFloat = 480) async -> UIImage? {
        let key = url
        if let cached = cached(key) { return cached }
        if failures.contains(key) { return nil }
        do {
            let data = try await app.library.imageData(url, for: book)
            var image = await Task.detached(priority: .userInitiated) { Self.downsample(data, maxPixel: maxPixel) }.value
            if image == nil, SVGImage.isSVG(data), let svg = SVGImage(data: data) {
                image = await Self.rasterize(svg, maxPixel: maxPixel)
            }
            guard let image else {
                failures.insert(key)
                return nil
            }
            images.setObject(image, forKey: key as NSString)
            return image
        } catch {
            if !(error is CancellationError) { failures.insert(key) }
            return nil
        }
    }

    /// 取封面主色：上半部、下半部、最鲜艳、最亮四色，用于书架 hero 卡与环境光
    func palette(for key: String, image: UIImage) async -> [Color] {
        if let box = palettes.object(forKey: key as NSString) { return box.colors }
        let colors = await Task.detached(priority: .utility) { Self.extract(image) }.value
        let result = colors.map { Color(uiColor: $0) }
        palettes.setObject(PaletteBox(colors: result), forKey: key as NSString)
        return result
    }

    nonisolated static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return UIImage(data: data) }
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else { return UIImage(data: data) }
        return UIImage(cgImage: cgImage)
    }

    nonisolated static func extract(_ image: UIImage) -> [UIColor] {
        guard let cg = image.cgImage else { return [] }
        let w = 6, h = 9
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var top = (0.0, 0.0, 0.0), bottom = (0.0, 0.0, 0.0)
        var vivid = (r: 0.0, g: 0.0, b: 0.0, score: -1.0)
        var bright = (r: 0.0, g: 0.0, b: 0.0, score: -1.0)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
                // CGContext 原点在左下，y 较小的行是图片下半部
                if y >= h / 2 { top.0 += r; top.1 += g; top.2 += b } else { bottom.0 += r; bottom.1 += g; bottom.2 += b }
                let maxC = max(r, g, b), minC = min(r, g, b)
                let saturation = maxC == 0 ? 0 : (maxC - minC) / maxC
                let vividScore = saturation * (0.4 + maxC)
                if vividScore > vivid.score { vivid = (r, g, b, vividScore) }
                let lum = 0.3 * r + 0.59 * g + 0.11 * b
                if lum > bright.score { bright = (r, g, b, lum) }
            }
        }
        let half = Double(w * h / 2)
        let c1 = UIColor(red: top.0 / half, green: top.1 / half, blue: top.2 / half, alpha: 1)
        let c2 = UIColor(red: bottom.0 / half, green: bottom.1 / half, blue: bottom.2 / half, alpha: 1)
        let c3 = UIColor(red: vivid.r, green: vivid.g, blue: vivid.b, alpha: 1)
        let c4 = UIColor(red: bright.r, green: bright.g, blue: bright.b, alpha: 1)
        return [c1, c2, c3, c4]
    }

    /// 封面纸张颗粒（原型 `--noise`）
    static let noise: UIImage = {
        let size = 128
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        var random = SeededRandom("noise")
        for i in 0..<(size * size) {
            let v = UInt8(random.next() * 255)
            bytes[i * 4] = v
            bytes[i * 4 + 1] = v
            bytes[i * 4 + 2] = v
            bytes[i * 4 + 3] = 255
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let cg = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return UIImage(cgImage: cg)
    }()
}

private final class PaletteBox {
    let colors: [Color]
    init(colors: [Color]) { self.colors = colors }
}

struct GrainOverlay: View {
    var opacity: Double = 0.28
    var blend: BlendMode = .overlay

    var body: some View {
        Image(uiImage: ImagePipeline.noise)
            .resizable(resizingMode: .tile)
            .blendMode(blend)
            .opacity(opacity)
            .allowsHitTesting(false)
    }
}
#endif
