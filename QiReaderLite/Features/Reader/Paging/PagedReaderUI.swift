import CoreText
import SwiftUI
import UIKit

/// UIPageViewController 的 SwiftUI 壳。
///
/// ⚠️ 容器必须能**按翻页方式重建**：`transitionStyle` / `navigationOrientation`
///    是 get-only 属性，只能在 init 里定，改方式就得换一个新实例。
final class PagedReaderController: UIViewController, UIGestureRecognizerDelegate {

    let pager = PagedChapterPager()
    /// 点击位置回调（0~1 横向比例），SwiftUI 侧用它决定是出菜单还是翻页
    var onTapZone: ((CGFloat) -> Void)?
    /// 让系统分页容器继续正常滚，不被 tap 抢
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }
    private var pageVC: UIPageViewController!
    private var mode: String = "slide"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        install(mode: mode)

        // ⚠️ tap 必须挂在 **UIKit 层**。
        //    以前 SwiftUI 层有个 SpatialTapGesture，重构成 UIViewController 后没了 ——
        //    点中间出不来目录。而且不能挂回 SwiftUI：UIScrollView 会吃掉 touch，
        //    SwiftUI 的 .onTapGesture 根本不触发。
        //    cancelsTouchesInView = false + shouldRecognizeSimultaneously
        //    → tap 和横向分页滑动同时生效，不打架。
        let tap = UITapGestureRecognizer(target: self, action: #selector(didTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        view.addGestureRecognizer(tap)
    }

    @objc private func didTap(_ gr: UITapGestureRecognizer) {
        let p = gr.location(in: view)
        guard view.bounds.width > 1 else { return }
        onTapZone?(max(0, min(1, p.x / view.bounds.width)))
    }

    private func install(mode newMode: String) {
        mode = newMode
        pageVC?.willMove(toParent: nil)
        pageVC?.view.removeFromSuperview()
        pageVC?.removeFromParent()

        let vc = pager.makeContainer(mode: newMode)
        addChild(vc)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        vc.didMove(toParent: self)
        view.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.topAnchor.constraint(equalTo: view.topAnchor),
            vc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            vc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        pageVC = vc
    }

    /// 翻页方式变了 → 换容器 → 把当前章重新灌进去
    func setMode(_ m: String) {
        guard m != mode, isViewLoaded else { mode = m; return }
        let ch = pager.chapter
        install(mode: m)
        pager.loadChapter(ch)
    }
}

/// 给 SwiftUI 用的 representable。
struct PagedReaderUI: UIViewControllerRepresentable {
    let controller: PagedReaderController

    func makeUIViewController(context: Context) -> PagedReaderController { controller }

    func updateUIViewController(_ c: PagedReaderController, context: Context) {}
}
