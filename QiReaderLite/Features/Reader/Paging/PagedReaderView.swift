import CoreText
import SwiftUI
import UIKit

/// 分页阅读器：正文按页排好，左右滑动翻页。
///
/// 抄的是栖阅那套原生分页（`ReaderPaginator` + `ReaderPageView` + `PageViewController`），
/// 不是 CSS 多列。翻页方式对应栖阅设置里的五种：
///   仿真     模拟真实翻书效果，页面卷曲翻转
///   滑动     类似 Apple Books 的左右滑动翻页
///   平移     左右平移动画翻页
///   无动画   无翻页动画，立即切换
///   上下滚动 上下滚动浏览，连续阅读体验（这个模式不用本视图，走 webview）
struct PagedReaderView: View {
    let text: String
    let title: String
    let config: ReaderLayoutConfig
    let mode: String

    /// 页码变化（1 起）：(当前页, 总页数)
    var onPageChange: (Int, Int) -> Void
    /// 翻到本章头(-1)/尾(+1) → 换章
    var onEdge: (Int) -> Void
    /// 点中间 → 出菜单
    var onMenu: () -> Void

    @State private var paginator = ReaderPaginator()
    @State private var pages: [ReaderPage] = []
    @State private var current = 0
    /// 拖动中的位移
    @State private var drag: CGFloat = 0
    /// 拖动中正在被拉进来的邻页
    @State private var incoming: Int?
    /// 视口尺寸
    @State private var viewport: CGSize = .zero
    /// 正在提交动画，提交期间不再接受新手势
    @State private var committing = false

    private var pageSize: CGSize {
        config.pageSize(in: viewport)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                Color(uiColor: config.backgroundColor).ignoresSafeArea()

                if text.isEmpty {
                    // 正文还没到（或者这一章确实是空的）——别显示空白页
                    Text("（本章没有内容）")
                        .font(.system(size: config.fontSize))
                        .foregroundStyle(Color(uiColor: config.textColor))
                } else if layoutLooksBroken {
                    // 分页结果明显不对（长文本只排出一页）→ 退回连续滚动，
                    // 宁可丑也不能让正文消失
                    ScrollView {
                        Text(text)
                            .font(Font(config.resolvedFont))
                            .foregroundStyle(Color(uiColor: config.textColor))
                            .lineSpacing(config.lineSpacing)
                            .padding(.horizontal, config.horizontalMargin)
                            .padding(.vertical, config.topMargin)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if mode == "flip" {
                    flipStack(width: w)
                } else {
                    slideStack(width: w)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(width: w))
            .simultaneousGesture(tapGesture(width: w))
            .onAppear { layout(in: geo.size) }
            .onChange(of: geo.size) { _, newSize in layout(in: newSize) }
            .onChange(of: text) { _, _ in layout(in: geo.size) }
            .onChange(of: config.fontSize) { _, _ in layout(in: geo.size) }
        }
        .background(Color(uiColor: config.backgroundColor).ignoresSafeArea())
    }

    /// 分页结果是不是明显不对。
    /// 正文很长却只排出一页 → 排版没生效（CoreText 没装上、页高算错等）。
    /// 这时候显示一个空白页是最糟的结果，宁可退回连续滚动。
    private var layoutLooksBroken: Bool {
        pages.count <= 1 && text.count > 400
    }

    // MARK: - 排版

    private func layout(in size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        viewport = size
        let ps = config.pageSize(in: size)
        let attr = config.attributed(text)
        let result = paginator.paginate(attr, pageSize: ps)
        pages = result
        if current >= result.count { current = max(0, result.count - 1) }
        onPageChange(current + 1, result.count)
    }

    // MARK: - 页面

    @ViewBuilder
    private func pageView(_ index: Int) -> some View {
        if pages.indices.contains(index) {
            ReaderPageCanvas(ctFrame: paginator.frame(at: index, pageSize: pageSize),
                             pageSize: pageSize,
                             bgColor: config.backgroundColor)
                .frame(width: pageSize.width, height: pageSize.height)
        } else {
            Color.clear
        }
    }

    // MARK: - 滑动 / 平移

    /// 滑动、平移、无动画共用：拖动时锚页跟着走，邻页从另一边进来。
    private func slideStack(width: CGFloat) -> some View {
        ZStack {
            if let inc = incoming {
                let dir: CGFloat = inc > current ? 1 : -1
                pageView(current)
                    .offset(x: drag)
                pageView(inc)
                    .offset(x: drag + dir * width)
            } else {
                pageView(current)
            }
        }
        .frame(width: width)
    }

    // MARK: - 仿真

    /// 仿真：当前页绕着边转，下一页在底下等着露出来。
    private func flipStack(width: CGFloat) -> some View {
        let w = max(width, 1)
        let t = drag / w                       // -1 ~ 1
        let forward = t <= 0
        let angle = Double(t * 180.0)          // 往前翻是负角，往回翻是正角
        let anchor: UnitPoint = forward ? .leading : .trailing
        let under: Int = incoming ?? (forward ? current + 1 : current - 1)

        return ZStack {
            if pages.indices.contains(under) {
                pageView(under)
            }
            pageView(current)
                .rotation3DEffect(.degrees(angle),
                                  axis: (x: 0, y: 1, z: 0),
                                  anchor: anchor,
                                  perspective: 0.4)
                // 转过 90° 就看不见了，直接藏掉，别让背面露出来
                .opacity(abs(angle) < 90 ? 1 : 0)
        }
        .frame(width: width)
    }

    // MARK: - 手势

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !committing else { return }
                let t = value.translation.width
                if incoming == nil {
                    let dir = t < 0 ? 1 : -1
                    let target = current + dir
                    // 越界也允许拖（到边了松手就换章），
                    // 但邻页只有真的存在时才建
                    if target >= 0 && target < pages.count {
                        incoming = target
                    }
                }
                drag = t
            }
            .onEnded { value in
                guard !committing else { return }
                let w = max(width, 1)
                let threshold = w * 0.25
                let moved = value.translation.width

                if let inc = incoming, abs(moved) >= threshold {
                    commit(to: inc, width: w)
                } else if incoming == nil {
                    // 邻页不存在 = 已经到本章头/尾了 → 换章
                    if abs(moved) >= threshold {
                        onEdge(moved < 0 ? 1 : -1)
                    }
                    withAnimation(.easeOut(duration: 0.18)) { drag = 0 }
                } else {
                    withAnimation(.easeOut(duration: 0.18)) { drag = 0 }
                }
            }
    }

    private func commit(to target: Int, width: CGFloat) {
        let dir: CGFloat = target > current ? 1 : -1
        committing = true
        if mode == "none" {
            // 无动画：直接切
            current = target
            incoming = nil
            drag = 0
            committing = false
            onPageChange(current + 1, pages.count)
            return
        }
        let duration: Double = (mode == "flat") ? 0.22 : 0.24
        let timing: Animation = (mode == "flat")
            ? .linear(duration: duration)
            : .easeInOut(duration: duration)
        withAnimation(timing) {
            drag = -dir * width
        }
        // 动画跑完再换页。这时几何完全一致（目标页已经在 0 位），换页不会有跳变。
        // ⚠️ 用项目里既成的 Task + MainActor.run 写法改 @State，
        //    不用 withAnimation 的 completion 重载（那个在 Swift 5 模式下签名容易踩坑）。
        Task {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000) + 20_000_000)
            await MainActor.run {
                current = target
                incoming = nil
                drag = 0
                committing = false
                onPageChange(current + 1, pages.count)
            }
        }
    }

    private func tapGesture(width: CGFloat) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard !committing else { return }
                let x = value.location.x
                let w = max(width, 1)
                if x < w * 0.25 {
                    goPage(-1)
                } else if x > w * 0.75 {
                    goPage(1)
                } else {
                    onMenu()
                }
            }
    }

    /// 点左/右 → 翻页；到本章头/尾 → 换章
    private func goPage(_ delta: Int) {
        let target = current + delta
        if target < 0 {
            onEdge(-1)
            return
        }
        if target >= pages.count {
            onEdge(1)
            return
        }
        current = target
        onPageChange(current + 1, pages.count)
    }
}
