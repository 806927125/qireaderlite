#if canImport(UIKit)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Design/CoverArt.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Design/CoverArt.swift

import SwiftUI
import UIKit

struct CoverPalette: Hashable, Sendable {
    let c1: UInt32, c2: UInt32, p2: UInt32, p3: UInt32, ink: UInt32

    var colors: [Color] { [c1, c2, p2, p3, ink].map { Color(hex: $0) } }
    var heroColors: [Color] { [Color(hex: c1), Color(hex: c2), Color(hex: p2), Color(hex: p3)] }

    static let all: [CoverPalette] = [
        .init(c1: 0x35535B, c2: 0x14232A, p2: 0x6F9C9B, p3: 0xDBE7DF, ink: 0xEEF4EF),
        .init(c1: 0x232A4A, c2: 0x0D1024, p2: 0x45568A, p3: 0xF2E6C9, ink: 0xF4EAD2),
        .init(c1: 0x3D434B, c2: 0x15171B, p2: 0x8D99A6, p3: 0xE8ECEF, ink: 0xF1F3F5),
        .init(c1: 0x5E2B26, c2: 0x261110, p2: 0xAB533D, p3: 0xF3D9B1, ink: 0xF6E7CF),
        .init(c1: 0x18203A, c2: 0x070A12, p2: 0x43557D, p3: 0xF0C27A, ink: 0xF3EAD8),
        .init(c1: 0xECE5D3, c2: 0xD8CDB3, p2: 0x3F3D38, p3: 0xA7382A, ink: 0x26241F),
        .init(c1: 0xE7A45A, c2: 0xB0502E, p2: 0xF6D29B, p3: 0xFFF3DD, ink: 0x3A1D10),
        .init(c1: 0x27322B, c2: 0x111712, p2: 0x6F8C68, p3: 0xF1D38A, ink: 0xEFE9D8),
        .init(c1: 0x3D3B37, c2: 0x191816, p2: 0xB2A790, p3: 0xE6DCCB, ink: 0xF2ECE1),
        .init(c1: 0xC7D2D6, c2: 0x8C9EA5, p2: 0xFFFFFF, p3: 0xF4F7F8, ink: 0x22303A),
        .init(c1: 0x0F3B4B, c2: 0x05141B, p2: 0x2D7B8D, p3: 0xBFE3E0, ink: 0xE4F4F2),
        .init(c1: 0x2D2523, c2: 0x110D0C, p2: 0x8B6B50, p3: 0xE7C9A0, ink: 0xF0E2CC),
        .init(c1: 0x3B3026, c2: 0x16110D, p2: 0xB28B5B, p3: 0xF3DCAE, ink: 0xF2E8D6),
        .init(c1: 0x4C302A, c2: 0x1E1210, p2: 0x9D5C49, p3: 0xEFD3B4, ink: 0xF5E6D3),
    ]
}

enum CoverMotif: CaseIterable {
    case rain, moon, grid, peaks, stars, ink, sun, lamp, rings, snow, waves, bell

    /// 每种配色搭配的图案（与原型书目一致），其余随机
    static func preferred(for palette: Int) -> CoverMotif? {
        let table: [CoverMotif] = [.rain, .moon, .grid, .peaks, .stars, .ink, .sun, .lamp, .rings, .snow, .waves, .bell, .lamp, .peaks]
        return table.indices.contains(palette) ? table[palette] : nil
    }
}

struct CoverDesign: Hashable {
    let seed: String
    let palette: CoverPalette
    let motif: CoverMotif

    init(seed: String) {
        self.seed = seed
        var random = SeededRandom(seed)
        let index = Int(random.next() * CGFloat(CoverPalette.all.count)) % CoverPalette.all.count
        palette = CoverPalette.all[index]
        motif = CoverMotif.preferred(for: index) ?? CoverMotif.allCases[Int(random.next() * 12) % 12]
    }
}

struct GeneratedCover: View {
    let design: CoverDesign
    let title: String
    let author: String
    var showsText = true

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let p = design.palette
            ZStack(alignment: .topTrailing) {
                LinearGradient(colors: [Color(hex: p.c1), Color(hex: p.c2)],
                               startPoint: UnitPoint(x: 0.65, y: 0), endPoint: UnitPoint(x: 0.35, y: 1))
                Canvas { context, size in
                    context.scaleBy(x: size.width / 120, y: size.height / 172)
                    var random = SeededRandom(design.seed)
                    CoverPainter.paint(design.motif, palette: p, in: &context, random: &random)
                }
                if showsText {
                    VerticalTitle(text: title, width: w, color: Color(hex: p.ink))
                        .padding(.top, w * 0.11)
                        .padding(.trailing, w * 0.11)
                    Text(author)
                        .font(.serif(max(6, w * 0.062), bold: false))
                        .tracking(w * 0.006)
                        .foregroundStyle(Color(hex: p.ink).opacity(0.78))
                        .lineLimit(1)
                        .frame(maxWidth: w * 0.62, alignment: .leading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(.leading, w * 0.1)
                        .padding(.bottom, w * 0.08)
                }
            }
        }
    }
}

private struct VerticalTitle: View {
    let text: String
    let width: CGFloat
    let color: Color

    var body: some View {
        let size = max(7, width * 0.13)
        let chars = Array(text.replacingOccurrences(of: " ", with: "").prefix(18))
        let columns = stride(from: 0, to: chars.count, by: 6).map { Array(chars[$0..<min($0 + 6, chars.count)]) }
        HStack(alignment: .top, spacing: size * 0.25) {
            ForEach(Array(columns.enumerated().reversed()), id: \.offset) { _, column in
                VStack(spacing: size * 0.15 + width * 0.016) {
                    ForEach(Array(column.enumerated()), id: \.offset) { _, char in
                        Text(String(char))
                            .font(.serif(size))
                            .frame(height: size)
                    }
                }
            }
        }
        .foregroundStyle(color)
        .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
    }
}

private enum CoverPainter {
    static func paint(_ motif: CoverMotif, palette p: CoverPalette, in c: inout GraphicsContext, random r: inout SeededRandom) {
        let p0 = Color(hex: p.c1), p1 = Color(hex: p.c2), p2 = Color(hex: p.p2), p3 = Color(hex: p.p3), p4 = Color(hex: p.ink)
        switch motif {
        case .rain:
            c.fill(circle(34, 68, 36), with: .radialGradient(Gradient(colors: [p3.opacity(0.6), p3.opacity(0)]),
                                                             center: CGPoint(x: 34, y: 68), startRadius: 0, endRadius: 36))
            c.fill(poly([(31.2, 70), (36.8, 70), (38.8, 118), (29.2, 118)]), with: .color(p1.opacity(0.85)))
            c.fill(circle(34, 67, 2.4), with: .color(p3))
            for _ in 0..<36 {
                let x = r.next() * 150 - 15, y = r.next() * 180 - 10, l = 8 + r.next() * 14
                let opacity = 0.1 + r.next() * 0.22
                c.stroke(line(x, y, x - l * 0.3, y + l), with: .color(p3.opacity(opacity)), lineWidth: 0.6)
            }
            c.fill(rect(0, 118, 120, 54), with: .color(p1.opacity(0.6)))
            var waves = Path()
            for y in [126.0, 136.0] {
                let a = y == 126 ? 4.0 : 3.0
                waves.move(to: CGPoint(x: 0, y: y))
                waves.addQuadCurve(to: CGPoint(x: 60, y: y), control: CGPoint(x: 30, y: y - a))
                waves.addQuadCurve(to: CGPoint(x: 120, y: y), control: CGPoint(x: 90, y: y + a))
            }
            c.stroke(waves, with: .color(p3.opacity(0.22)), lineWidth: 0.6)
        case .moon:
            c.fill(circle(38, 50, 31), with: .color(p3.opacity(0.07)))
            c.fill(circle(38, 50, 17), with: .color(p3.opacity(0.93)))
            c.fill(relative(0, 116, [(18, -16), (12, 8), (18, -20), (18, 18), (16, -10), (18, 14), (20, -8)], closeTo: 172),
                   with: .color(p2.opacity(0.5)))
            c.fill(relative(0, 132, [(24, -14), (20, 10), (26, -14), (26, 14), (24, -8)], closeTo: 172), with: .color(p1.opacity(0.88)))
            for i in 0..<4 {
                let d = CGFloat(i)
                c.stroke(line(26 + d * 3, 142 + d * 6, 50 - d * 3, 142 + d * 6), with: .color(p3.opacity(0.35 - d * 0.07)), lineWidth: 0.8)
            }
            c.fill(poly([(62, 150), (76, 150), (73, 154), (65, 154)]), with: .color(p3.opacity(0.6)))
        case .grid:
            for i in 1..<7 {
                c.stroke(line(0, CGFloat(i) * 14, 120, CGFloat(i) * 14), with: .color(p3.opacity(0.07)), lineWidth: 0.5)
            }
            var x: CGFloat = -2
            while x < 120 {
                let w = 8 + r.next() * 14, h = 30 + r.next() * 64
                c.fill(rect(x, 172 - h, w, h), with: .color(p1.opacity(0.6 + r.next() * 0.35)))
                var wy = 172 - h + 5
                while wy < 168 {
                    var wx = x + 2
                    while wx < x + w - 2 {
                        if r.next() < 0.16 { c.fill(rect(wx, wy, 1.6, 2.4), with: .color(p3.opacity(0.75))) }
                        wx += 4
                    }
                    wy += 6
                }
                x += w + 1.5
            }
            c.stroke(circle(28, 40, 11), with: .color(p3.opacity(0.5)), lineWidth: 0.8)
            var hands = Path()
            hands.move(to: CGPoint(x: 28, y: 33))
            hands.addLine(to: CGPoint(x: 28, y: 40))
            hands.addLine(to: CGPoint(x: 32, y: 43))
            c.stroke(hands, with: .color(p3.opacity(0.7)), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
        case .peaks:
            c.fill(circle(34, 58, 14), with: .color(p3.opacity(0.85)))
            c.fill(poly([(0, 172), (0, 118), (18, 92), (30, 110), (48, 62), (62, 98), (76, 80), (96, 120), (120, 96), (120, 172)]),
                   with: .color(p2.opacity(0.75)))
            c.fill(poly([(0, 172), (0, 140), (22, 120), (40, 136), (62, 112), (86, 140), (104, 126), (120, 138), (120, 172)]),
                   with: .color(p1.opacity(0.92)))
            c.fill(poly([(48, 62), (52, 74), (47, 72)]), with: .color(p3.opacity(0.6)))
            var arcs = Path()
            arcs.move(to: CGPoint(x: 10, y: 84))
            arcs.addQuadCurve(to: CGPoint(x: 26, y: 84), control: CGPoint(x: 18, y: 80))
            arcs.move(to: CGPoint(x: 70, y: 70))
            arcs.addQuadCurve(to: CGPoint(x: 82, y: 70), control: CGPoint(x: 76, y: 67))
            c.stroke(arcs, with: .color(p3.opacity(0.4)), lineWidth: 0.7)
        case .stars:
            for _ in 0..<70 {
                let x = r.next() * 120, y = r.next() * 130, radius = 0.25 + r.next() * 0.9, opacity = 0.25 + r.next() * 0.7
                c.fill(circle(x, y, radius), with: .color(p4.opacity(opacity)))
            }
            let points: [(CGFloat, CGFloat)] = [(18, 40), (34, 52), (30, 72), (50, 84), (44, 104)]
            var constellation = Path()
            constellation.addLines(points.map { CGPoint(x: $0.0, y: $0.1) })
            c.stroke(constellation, with: .color(p3.opacity(0.55)), lineWidth: 0.6)
            for point in points { c.fill(circle(point.0, point.1, 1.5), with: .color(p3)) }
            c.fill(circle(60, 252, 110), with: .color(p2.opacity(0.55)))
            c.stroke(circle(60, 252, 110), with: .color(p3.opacity(0.5)), lineWidth: 0.8)
        case .ink:
            c.fill(quads(0, 120, [(16, -24, 30, -16), (14, -28, 30, -6), (14, -14, 28, 4), (16, -12, 32, 4)], closeTo: 172),
                   with: .color(p2.opacity(0.16)))
            c.fill(quads(0, 138, [(20, -26, 38, -14), (16, -24, 34, -2), (18, -14, 48, 6)], closeTo: 172), with: .color(p2.opacity(0.3)))
            c.fill(quads(0, 154, [(26, -18, 50, -8), (26, -14, 70, 4)], closeTo: 172), with: .color(p2.opacity(0.55)))
            c.fill(Path(roundedRect: CGRect(x: 14, y: 20, width: 12, height: 12), cornerRadius: 1.5), with: .color(p3.opacity(0.92)))
            var seal = Path()
            seal.move(to: CGPoint(x: 17, y: 24)); seal.addLine(to: CGPoint(x: 23, y: 24))
            seal.move(to: CGPoint(x: 17, y: 28)); seal.addLine(to: CGPoint(x: 23, y: 28))
            seal.move(to: CGPoint(x: 20, y: 22)); seal.addLine(to: CGPoint(x: 20, y: 30))
            c.stroke(seal, with: .color(p0), lineWidth: 0.9)
            var ripple = Path()
            ripple.move(to: CGPoint(x: 40, y: 62))
            ripple.addQuadCurve(to: CGPoint(x: 52, y: 62), control: CGPoint(x: 46, y: 59))
            ripple.addQuadCurve(to: CGPoint(x: 64, y: 62), control: CGPoint(x: 58, y: 65))
            c.stroke(ripple, with: .color(p2.opacity(0.35)), lineWidth: 0.7)
        case .sun:
            var clipped = c
            clipped.clip(to: rect(0, 0, 120, 112))
            clipped.fill(circle(46, 96, 38), with: .color(p2))
            for i in 0..<5 {
                let d = CGFloat(i)
                c.fill(rect(0, 82 + d * 6 + d * d * 0.6, 120, 1.2 + d * 0.9), with: .color(p0))
            }
            c.fill(rect(0, 112, 120, 60), with: .color(p1.opacity(0.55)))
            var lines = Path()
            for y in [124.0, 136.0, 150.0] {
                lines.move(to: CGPoint(x: 0, y: y)); lines.addLine(to: CGPoint(x: 120, y: y))
            }
            c.stroke(lines, with: .color(p3.opacity(0.18)), lineWidth: 0.6)
        case .lamp:
            var posts = Path()
            posts.move(to: CGPoint(x: 8, y: 40)); posts.addLine(to: CGPoint(x: 8, y: 172))
            posts.move(to: CGPoint(x: 72, y: 40)); posts.addLine(to: CGPoint(x: 72, y: 172))
            c.stroke(posts, with: .color(p1.opacity(0.55)), lineWidth: 6)
            c.fill(poly([(0, 40), (86, 40), (80, 32), (6, 32)]), with: .color(p1.opacity(0.6)))
            c.fill(circle(40, 92, 46), with: .radialGradient(
                Gradient(stops: [.init(color: p3.opacity(0.7), location: 0), .init(color: p3.opacity(0.18), location: 0.35),
                                 .init(color: p3.opacity(0), location: 1)]),
                center: CGPoint(x: 40, y: 92), startRadius: 0, endRadius: 46))
            var flame = Path()
            flame.move(to: CGPoint(x: 40, y: 79))
            flame.addQuadCurve(to: CGPoint(x: 40, y: 92), control: CGPoint(x: 35.5, y: 85.5))
            flame.addQuadCurve(to: CGPoint(x: 40, y: 79), control: CGPoint(x: 44.5, y: 85.5))
            c.fill(flame, with: .color(p3))
            c.fill(Path(roundedRect: CGRect(x: 35, y: 92, width: 10, height: 5), cornerRadius: 1), with: .color(p3.opacity(0.7)))
            c.fill(rect(38, 97, 4, 22), with: .color(p1.opacity(0.9)))
        case .rings:
            for i in 1...9 {
                let d = CGFloat(i)
                c.stroke(circle(42, 96, d * 8), with: .color(p3.opacity(0.5 - d * 0.045)), lineWidth: 0.7)
            }
            c.fill(circle(42, 96, 2.4), with: .color(p3))
            c.fill(relative(0, 150, [(30, -12), (22, 8), (28, -14), (40, 12)], closeTo: 172), with: .color(p1.opacity(0.72)))
        case .snow:
            var hill = Path()
            hill.move(to: CGPoint(x: 0, y: 128))
            hill.addQuadCurve(to: CGPoint(x: 60, y: 124), control: CGPoint(x: 30, y: 116))
            hill.addQuadCurve(to: CGPoint(x: 120, y: 120), control: CGPoint(x: 90, y: 132))
            hill.addLine(to: CGPoint(x: 120, y: 172)); hill.addLine(to: CGPoint(x: 0, y: 172)); hill.closeSubpath()
            c.fill(hill, with: .color(p2.opacity(0.85)))
            var front = Path()
            front.move(to: CGPoint(x: 0, y: 142))
            front.addQuadCurve(to: CGPoint(x: 70, y: 140), control: CGPoint(x: 36, y: 132))
            front.addQuadCurve(to: CGPoint(x: 120, y: 136), control: CGPoint(x: 104, y: 148))
            front.addLine(to: CGPoint(x: 120, y: 172)); front.addLine(to: CGPoint(x: 0, y: 172)); front.closeSubpath()
            c.fill(front, with: .color(p3))
            c.fill(poly([(30, 122), (33, 112), (36, 122)]), with: .color(p1.opacity(0.75)))
            c.fill(poly([(38, 124), (40.4, 116), (42.8, 124)]), with: .color(p1.opacity(0.75)))
            for _ in 0..<46 {
                let x = r.next() * 120, y = r.next() * 150, radius = 0.4 + r.next() * 1.1, opacity = 0.5 + r.next() * 0.5
                c.fill(circle(x, y, radius), with: .color(.white.opacity(opacity)))
            }
        case .waves:
            c.stroke(circle(36, 54, 10), with: .color(p3.opacity(0.6)), lineWidth: 0.8)
            c.fill(circle(36, 54, 3), with: .color(p3.opacity(0.8)))
            for i in 0..<6 {
                let y = 92 + CGFloat(i) * 14, a = 5 + CGFloat(i) * 1.2
                var wave = Path()
                wave.move(to: CGPoint(x: -10, y: y))
                for k in 0..<8 {
                    let kk = CGFloat(k)
                    wave.addQuadCurve(to: CGPoint(x: -10 + (kk + 1) * 20, y: y),
                                      control: CGPoint(x: -10 + kk * 20 + 10, y: y + (k % 2 == 1 ? a : -a)))
                }
                wave.addLine(to: CGPoint(x: 150, y: 172)); wave.addLine(to: CGPoint(x: -10, y: 172)); wave.closeSubpath()
                c.fill(wave, with: .color((i % 2 == 1 ? p2 : p1).opacity(0.35 + CGFloat(i) * 0.1)))
            }
        case .bell:
            c.stroke(line(40, 14, 40, 28), with: .color(p3.opacity(0.8)), lineWidth: 1.2)
            var bell = Path()
            bell.move(to: CGPoint(x: 26, y: 46))
            bell.addQuadCurve(to: CGPoint(x: 40, y: 28), control: CGPoint(x: 26, y: 30))
            bell.addQuadCurve(to: CGPoint(x: 54, y: 46), control: CGPoint(x: 54, y: 30))
            bell.addLine(to: CGPoint(x: 56, y: 70))
            bell.addQuadCurve(to: CGPoint(x: 62, y: 78), control: CGPoint(x: 58, y: 76))
            bell.addLine(to: CGPoint(x: 18, y: 78))
            bell.addQuadCurve(to: CGPoint(x: 24, y: 70), control: CGPoint(x: 22, y: 76))
            bell.closeSubpath()
            c.fill(bell, with: .color(p3.opacity(0.82)))
            c.fill(circle(40, 82, 3), with: .color(p3.opacity(0.82)))
            c.stroke(line(18, 150, 104, 96), with: .color(p3.opacity(0.55)), lineWidth: 1.1)
            c.stroke(line(24, 152, 30, 142), with: .color(p3.opacity(0.55)), lineWidth: 2)
            c.fill(rect(0, 160, 120, 12), with: .color(p1.opacity(0.6)))
        }
    }

    private static func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    private static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Path {
        Path(CGRect(x: x, y: y, width: w, height: h))
    }

    private static func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: x1, y: y1))
        path.addLine(to: CGPoint(x: x2, y: y2))
        return path
    }

    private static func poly(_ points: [(CGFloat, CGFloat)]) -> Path {
        var path = Path()
        path.addLines(points.map { CGPoint(x: $0.0, y: $0.1) })
        path.closeSubpath()
        return path
    }

    /// 相对折线（SVG 小写 l），最后竖直落到 `closeTo` 并回到起点
    private static func relative(_ x: CGFloat, _ y: CGFloat, _ steps: [(CGFloat, CGFloat)], closeTo bottom: CGFloat) -> Path {
        var path = Path()
        var point = CGPoint(x: x, y: y)
        path.move(to: point)
        for step in steps {
            point = CGPoint(x: point.x + step.0, y: point.y + step.1)
            path.addLine(to: point)
        }
        path.addLine(to: CGPoint(x: point.x, y: bottom))
        path.addLine(to: CGPoint(x: x, y: bottom))
        path.closeSubpath()
        return path
    }

    /// 相对二次曲线（SVG 小写 q）
    private static func quads(_ x: CGFloat, _ y: CGFloat, _ steps: [(CGFloat, CGFloat, CGFloat, CGFloat)], closeTo bottom: CGFloat) -> Path {
        var path = Path()
        var point = CGPoint(x: x, y: y)
        path.move(to: point)
        for step in steps {
            let control = CGPoint(x: point.x + step.0, y: point.y + step.1)
            point = CGPoint(x: point.x + step.2, y: point.y + step.3)
            path.addQuadCurve(to: point, control: control)
        }
        path.addLine(to: CGPoint(x: point.x, y: bottom))
        path.addLine(to: CGPoint(x: x, y: bottom))
        path.closeSubpath()
        return path
    }
}
#endif
