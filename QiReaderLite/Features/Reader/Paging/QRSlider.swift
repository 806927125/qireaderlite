import SwiftUI

/// 照 ui.txt 的 `<input type="range">` **自绘**的滑块。
///
/// ```
/// input[type="range"] { width:100%; height:6px; border-radius:3px;
///     background: linear-gradient(to right, #4a90d9 var(--p,30%), rgba(0,0,0,.12) var(--p,30%)); }
/// input[type="range"]::-webkit-slider-thumb { width:26px; height:26px; border-radius:50%;
///     background:#fff; box-shadow:0 2px 8px rgba(0,0,0,.25); }
/// ```
///
/// ── 为什么不用系统 `Slider` ──
/// 连续两次真机反馈「滑块被挡了一点」「上面被挡」：
///   · iOS 26 的系统 `Slider` **frame 高度比 thumb 直径小**，thumb 上下溢出
///     自己 frame 画的 → 裁切 / 与相邻控件打架；
///   · 系统样式的滑轨粗细、thumb 造型跟栖阅对不上。
///
/// 自绘之后：轨道 6、thumb 26、白圆带阴影、已填充段蓝色 ——
/// **和 ui.txt 逐项一致**，也不受系统版本影响。
struct QRSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var accent: Color = Color(red: 74 / 255, green: 144 / 255, blue: 217 / 255)

    /// thumb 直径（ui.txt 的 26px）
    private let thumb: CGFloat = 26
    /// 轨道高（ui.txt 的 6px）
    private let track: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            // 两端各留半个 thumb 的位置，thumb 才不会跑到 frame 外面
            let usable = max(w - thumb, 1)
            let ratio = min(max((value - range.lowerBound)
                                 / max(range.upperBound - range.lowerBound, 0.0001), 0), 1)
            let x = thumb / 2 + usable * ratio
            ZStack(alignment: .leading) {
                // 未填充段
                Capsule().fill(Color.black.opacity(0.12))
                    .frame(height: track)
                // 已填充段
                Capsule().fill(accent)
                    .frame(width: max(x, 0), height: track)
                // thumb
                Circle().fill(.white)
                    .frame(width: thumb, height: thumb)
                    .shadow(color: Color.black.opacity(0.25), radius: 8, y: 2)
                    .offset(x: x - thumb / 2)
            }
            .frame(height: thumb)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let r = min(max((g.location.x - thumb / 2) / usable, 0), 1)
                        let raw = range.lowerBound + r * (range.upperBound - range.lowerBound)
                        value = step >= 1 ? (raw / step).rounded() * step : raw
                    }
            )
        }
        .frame(height: thumb)
    }
}
