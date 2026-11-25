#if canImport(SwiftUI)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/App/Appearance.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/App/Appearance.swift

import Observation
import SwiftUI
import UIKit

enum CircularReveal {
    static func perform(in window: UIWindow, origin: CGPoint?, change: () -> Void) {
        guard let snapshot = window.snapshotView(afterScreenUpdates: false) else {
            change()
            return
        }
        snapshot.isUserInteractionEnabled = false
        window.addSubview(snapshot)
        change()

        let bounds = window.bounds
        let center = origin ?? CGPoint(x: bounds.midX, y: 30)
        let radius = hypot(max(center.x, bounds.width - center.x), max(center.y, bounds.height - center.y)) + 8
        let mask = CAShapeLayer()
        mask.fillRule = .evenOdd
        mask.frame = bounds
        let start = holePath(bounds, center: center, radius: 0.1)
        let end = holePath(bounds, center: center, radius: radius)
        mask.path = end
        snapshot.layer.mask = mask

        CATransaction.begin()
        CATransaction.setCompletionBlock { snapshot.removeFromSuperview() }
        let animation = CABasicAnimation(keyPath: "path")
        animation.fromValue = start
        animation.toValue = end
        animation.duration = 0.68
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.2, 1)
        mask.add(animation, forKey: "reveal")
        CATransaction.commit()
    }

    private static func holePath(_ rect: CGRect, center: CGPoint, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addRect(rect)
        path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        return path
    }
}
#endif
