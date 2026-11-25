#if os(iOS)
// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/Design/Fonts.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/Design/Fonts.swift

import CoreText
import Observation
import SwiftUI
import UIKit

@Observable
final class FontLibrary {
    static let shared = FontLibrary()

    static let songti = "STSongti-SC-Regular"
    static let songtiBold = "STSongti-SC-Bold"
    /// iOS 10 / macOS 10.12 之后楷体不再带中间的连字符。旧名留着，老系统还能用
    static let kaiti = "STKaitiSC-Regular"
    static let kaitiBold = "STKaitiSC-Bold"
    private static let kaitiLegacy = "STKaiti-SC-Regular"
    private static let kaitiLegacyBold = "STKaiti-SC-Bold"

    private(set) var songtiReady = false
    private(set) var kaitiReady = false

    private init() {
        songtiReady = UIFont(name: Self.songtiBold, size: 12) != nil
        kaitiReady = Self.hasKaiti
    }

    /// 本机真正装上的那个楷体名。新名优先，没有再退回旧名
    static func kaitiName(bold: Bool) -> String {
        let modern = bold ? kaitiBold : kaiti
        let legacy = bold ? kaitiLegacyBold : kaitiLegacy
        if UIFont(name: modern, size: 12) != nil { return modern }
        if UIFont(name: legacy, size: 12) != nil { return legacy }
        return modern
    }

    private static var hasKaiti: Bool {
        UIFont(name: kaiti, size: 12) != nil || UIFont(name: kaitiLegacy, size: 12) != nil
    }

    func prepare() {
        request([Self.songti, Self.songtiBold]) { [weak self] in self?.songtiReady = true }
        request([Self.kaiti, Self.kaitiBold]) { [weak self] in self?.kaitiReady = Self.hasKaiti }
        request([Self.kaitiLegacy, Self.kaitiLegacyBold]) { [weak self] in self?.kaitiReady = Self.hasKaiti }
    }

    func isReady(_ name: String?) -> Bool {
        guard let name else { return true }
        return UIFont(name: name, size: 12) != nil
    }

    private func request(_ names: [String], done: @escaping @MainActor () -> Void) {
        Self.download(names) { ok in
            Task { @MainActor in if ok { done() } }
        }
    }

    nonisolated private static func download(_ names: [String], completion: @escaping @Sendable (Bool) -> Void) {
        let descriptors = names.map { CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: $0] as CFDictionary) }
        CTFontDescriptorMatchFontDescriptorsWithProgressHandler(descriptors as CFArray, nil) { state, _ in
            switch state {
            case .didFinish:
                completion(true)
            case .didFailWithError:
                completion(false)
            default:
                break
            }
            return true
        }
    }
}
#endif
