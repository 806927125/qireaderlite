import CoreText
import SwiftUI
import UIKit

/// UIPageViewController 的 SwiftUI 壳。
///
/// 翻转/卷曲/滑动的手势与动画全在 UIKit 侧，这里只负责：
///  · 把 SwiftUI 的配置同步进 pager
///  · 把 UIPageViewController 的实例还给上层做命令式操作（show/reportFailure/retry）
final class PagedReaderController: UIViewController {

    let pageVC: UIPageViewController
    let pager = PagedChapterPager()

    init() {
        pageVC = UIPageViewController(transitionStyle: .scroll,
                                      navigationOrientation: .horizontal)
        super.init(nibName: nil, bundle: nil)
        addChild(pageVC)
        pageVC.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pageVC.view)
        NSLayoutConstraint.activate([
            pageVC.view.topAnchor.constraint(equalTo: view.topAnchor),
            pageVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pageVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pageVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        pageVC.didMove(toParent: self)
        pager.build(vc: pageVC)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 给 SwiftUI 用的 representable。
struct PagedReaderUI: UIViewControllerRepresentable {
    let controller: PagedReaderController

    func makeUIViewController(context: Context) -> PagedReaderController { controller }

    func updateUIViewController(_ c: PagedReaderController, context: Context) {}
}
