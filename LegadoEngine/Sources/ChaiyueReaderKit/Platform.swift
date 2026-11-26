// ⭐⭐⭐⭐⭐ **平台条件编译补丁**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//   · 本文件依赖 **TextKit / AppKit**（`NSTextContainer` / `NSLayoutManager` / `NSBezierPath` …）
//   ⇒ **只有 iOS/macOS 能编** ⇒ Linux 沙盒编不到 ⇒ 用条件编译隔离 ⭐⭐⭐
//   ⇒ Apple 平台功能**完全不变**；Linux 上这些类型不存在（只有 `ChaiyueReader` 用到它们，而它本身也是 iOS-only）⭐⭐⭐
#if canImport(UIKit) || canImport(AppKit)
import Foundation

#if canImport(UIKit)
import UIKit
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
public typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
public typealias PlatformImage = NSImage
#endif

extension PlatformColor {
    /// 解析 `#RRGGBB` 或 `#AARRGGBB`
    public convenience init(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: text).scanHexInt64(&value)
        let a, r, g, b: CGFloat
        if text.count == 8 {
            a = CGFloat((value >> 24) & 0xFF) / 255
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
        } else {
            a = 1
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}

extension PlatformFont {
    static func readerFont(name: String?, size: CGFloat, bold: Bool = false) -> PlatformFont {
        if let name, !name.isEmpty, let font = PlatformFont(name: name, size: size) {
            return font
        }
        return bold ? PlatformFont.boldSystemFont(ofSize: size) : PlatformFont.systemFont(ofSize: size)
    }
}
#endif  // #if canImport(UIKit) || canImport(AppKit)
