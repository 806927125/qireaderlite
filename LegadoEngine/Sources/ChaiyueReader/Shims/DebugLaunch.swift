// ⭐⭐⭐⭐⭐ **自柴阅 App/Sources/App/DebugLaunch.swift 搬运**（2026-11-25 · 柴阅阅读器整包 vendor · 子任务 A「编译闭环」）
//
// ⚠️ **许可**：柴阅（github.com/Lincb522/Chaiyue）= **GPL-3.0** ⇒ 本文件是柴阅源码 ⭐⭐⭐
// 原文件：App/Sources/App/DebugLaunch.swift

import Foundation
import ChaiyueReaderKit
import ChaiyueModels
import ChaiyueReaderServices

/// 柴阅的标签栏枚举（App 层；轻阅只有「发现」这一屏 ⇒ 保留类型面）⭐⭐⭐
enum MainTab: Int, CaseIterable, Identifiable {
    case shelf, explore, me
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .shelf: "书架"
        case .explore: "发现"
        case .me: "我的"
        }
    }
}

enum DebugLaunch {
    static func run(_ app: AppModel) async {
        let args = ProcessInfo.processInfo.arguments
        func value(_ key: String) -> String? {
            guard let index = args.firstIndex(of: "-" + key), index + 1 < args.count else { return nil }
            return args[index + 1]
        }

        let fm = FileManager.default
        let seed = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Seed", isDirectory: true)
        if let files = try? fm.contentsOfDirectory(at: seed, includingPropertiesForKeys: nil) {
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                await app.importFile(file)
                try? fm.removeItem(at: file)
            }
        }

        if let raw = value("kokoroTest") {
            if let threads = value("kokoroThreads").flatMap(Int.init) { LocalVoice.threads = threads }
            if let provider = value("kokoroProvider") { LocalVoice.provider = provider }
            let speaker = Int(raw) ?? LocalVoice.defaultSpeaker
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            var log: [String] = []
            for (index, line) in ["雨是后半夜停的。巷子里的青石板还湿着，路灯把影子拉得很长。",
                                  "他把信折好放回口袋，抬头看了一眼对面那扇亮着的窗，2026年11月7日。"].enumerated() {
                let started = Date()
                let audio = try? await app.localVoice.audio(line, speaker: speaker, speed: 1)
                log.append("line\(index) elapsed=\(Date().timeIntervalSince(started)) bytes=\(audio?.data.count ?? 0)")
                try? audio?.data.write(to: docs.appendingPathComponent("kokoro_test\(index).wav"))
            }
            try? log.joined(separator: "\n").write(to: docs.appendingPathComponent("kokoro_test.txt"), atomically: true, encoding: .utf8)
        }
        if let raw = value("appearance"), let mode = AppearanceMode(rawValue: raw) {
            app.appearance.set(mode)
        }
        if let raw = value("tab") {
            app.tab = MainTab.allCases.first { "\($0)" == raw } ?? .shelf
        }
        if let keyword = value("search") {
            app.startSearch(keyword)
            if let index = value("openResult").flatMap(Int.init) {
                let search = app.library.search
                var waited = 0
                while waited < 80, search.results.count <= index, search.isSearching || search.results.isEmpty {
                    try? await Task.sleep(for: .milliseconds(500))
                    waited += 1
                }
                if !search.results.isEmpty {
                    let book = search.results[min(index, search.results.count - 1)]
                    var target = book.primary.toBook()
                    if target.coverUrl.nilIfEmpty == nil { target.coverUrl = book.coverUrl }
                    app.openDetail(target, alternatives: book.items, sourceID: "search-\(book.key)")
                }
            }
        }
        if let raw = value("route") {
            let routes: [String: Route] = [
                "sources": .sources, "replaceRules": .replaceRules, "tocRules": .tocRules, "cache": .cache, "reading": .reading, "fonts": .fonts,
                "speech": .speech, "backup": .backup, "about": .about, "sourceEditor": .sourceEditor(url: nil),
                "readerThemes": .readerThemes,
            ]
            if let route = routes[raw] { app.path = [route] }
        }
        if value("voicePackDownload") != nil {
            app.voiceStore.download()
        }
        func shelfBook(_ name: String) -> Book? {
            app.library.shelf.books.first { $0.name == name } ?? app.library.shelf.books.first { $0.name.contains(name) }
        }
        if let name = value("detail"), let book = shelfBook(name) {
            app.openDetail(book)
        }
        if let raw = value("pageStyle"), let style = PageTurnStyle(rawValue: raw) {
            app.settings.pageStyle = style
        }
        if let id = value("readerTheme"), let theme = ReaderThemeSpec.find(id) {
            app.settings.select(theme)
        }
        if let raw = value("laterToast") {
            try? await Task.sleep(for: .seconds(2))
            app.island.show("checkmark", "已加入书架", duration: max(2.2, Double(raw) ?? 0))
        }
        if let raw = value("laterTab") {
            try? await Task.sleep(for: .seconds(2))
            app.tab = MainTab.allCases.first { "\($0)" == raw } ?? .shelf
        }
        if let name = value("read"), let book = shelfBook(name) {
            try? await Task.sleep(for: .milliseconds(value("readDelay").flatMap(Int.init) ?? 400))
            let key = ["hero-", "grid-"].map { $0 + book.bookUrl }.first { app.coverFrames[$0] != nil }
            app.openReader(book, coverKey: key)
        }
    }

    static func flag(_ key: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-" + key), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}


// MARK: - 阅读器宿主补的面（轻阅没有的 App 层能力 ⇒ 最小实现）⭐⭐⭐

extension AppModel {
    /// 标签栏（轻阅阅读器用不到 ⇒ 固定「发现」）⭐⭐⭐
    var tab: MainTab = .shelf

    /// 导入本地文件（轻阅阅读器不接 ⇒ 空实现）⭐⭐⭐
    func importFile(_ url: URL) {}
}


// MARK: - 搜索路由（轻阅阅读器不接搜索 ⇒ 最小面）⭐⭐⭐

/// 搜索结果打开的路由（轻阅：空实现）
enum Route: Hashable {
    case reader(Book)
    case source(String)
}

/// 触发搜索（轻阅阅读器不接 ⇒ 空实现）
func startSearch(_ keyword: String) {}

extension ChaiyueReaderLibrary {
    /// 搜索（轻阅阅读器不接 ⇒ 空实现）
    func search(_ keyword: String) -> [SearchBook] { [] }
}
