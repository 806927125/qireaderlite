import Foundation
import UIKit

enum Toast {
    // ⭐⭐⭐⭐⭐ **必须切主线程**（2026-10-25 真机闪退实证）
    //
    // **事故**：build248 加了 `java.longToast` 的宿主实现 ⇒ 站方第一次真的调到宿主
    // ⇒ 引擎在**后台线程**跑 ⇒ `Toast.show` 在后台线程建 `UILabel` / 碰 `UIApplication`
    // ⇒ **UIKit 主线程违规 ⇒ 闪退**（点「发现」就退）⭐⭐⭐
    //
    // ⚠️ **为什么以前没事**：`java.toast` 走引擎自己那条路（不落宿主）⇒ 这个函数一直没人从后台调
    // ⇒ 一旦新增走宿主的 API（如 longToast）⇒ **立刻踩雷** ⇒ 所以要**根治**，不是在这一个调用点打补丁 ⭐
    //
    // ⇒ 修法：① 渲染部分标 `@MainActor`（**编译器从此强制所有调用点处理隔离**）
    //        ② 入口自己切主线程（谁调都安全）
    static func show(_ text: String) {
        // ⭐ 永远切主线程（哪怕已经在主线程也无妨 ⇒ 少一帧无所谓 ⇒ 绝不多一个崩溃点）
        DispatchQueue.main.async { MainActor.assumeIsolated { render(text) } }
    }

    /// ⭐ **UIKit 渲染**（只能在主线程）
    @MainActor
    private static func render(_ text: String) {
        let lbl = UILabel()
        lbl.text = text
        lbl.font = .systemFont(ofSize: 15, weight: .medium)
        lbl.textColor = .white
        lbl.backgroundColor = Terminal.toastBg
        lbl.textAlignment = .center
        lbl.numberOfLines = 0
        lbl.alpha = 0
        lbl.layer.cornerRadius = 12
        lbl.layer.masksToBounds = true
        lbl.translatesAutoresizingMaskIntoConstraints = false
        let host = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.keyWindow ?? UIWindow()
        host.addSubview(lbl)
        NSLayoutConstraint.activate([
            lbl.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            lbl.bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.bottomAnchor, constant: -90),
            lbl.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
        ])
        UIView.animate(withDuration: 0.2) { lbl.alpha = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            UIView.animate(withDuration: 0.3, animations: { lbl.alpha = 0 }) { _ in lbl.removeFromSuperview() }
        }
    }
}
