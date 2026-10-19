import CoreText
import SwiftUI
import UIKit

/// UIPageViewController 的 SwiftUI 壳。
///
/// ⚠️ 容器必须能**按翻页方式重建**：`transitionStyle` / `navigationOrientation`
///    是 get-only 属性，只能在 init 里定，改方式就得换一个新实例。
final class PagedReaderController: UIViewController {

    let pager = PagedChapterPager()
    private var pageVC: UIPageViewController!
    private var mode: String = "slide"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        install(mode: mode)
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
        let text = pager.lastText, title = pager.lastTitle
        install(mode: m)
        if !text.isEmpty { pager.reload(text: text, title: title, keepSlot: 0) }
    }
}

/// 给 SwiftUI 用的 representable。
struct PagedReaderUI: UIViewControllerRepresentable {
    let controller: PagedReaderController

    func makeUIViewController(context: Context) -> PagedReaderController { controller }

    func updateUIViewController(_ c: PagedReaderController, context: Context) {}
}
