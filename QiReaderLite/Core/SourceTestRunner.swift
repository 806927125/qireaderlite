import Foundation

/// **「测书源」** —— 单独挑一个书源，跑完整链路，看它到底能不能用、断在哪一步。
///
/// ⭐ 对齐栖阅的 `SourceFullTestView`（用户给的截图）：
///   栖阅那个测试器是 **分阶段 + 分步计时** 的：
///     发现功能 20 本书 → 书籍详情（作者/最新章节）
///     → 目录列表 共 53 章（通过 2.32s）→ 正文内容 3582 字（通过 1.38s）
///     顶部还显示「测试结果：通过 4 · 失败 0 · 耗时…」
///   面板入口有 8 个：搜索/发现/详情/目录/正文**五份源码** + JS控制台 +
///   系统日志 + **诊断时间线** + 复制测试报告 + 重置测试 + 清除配置变量
///
/// ⇒ 轻阅原来只有「引擎日志」一坨流水 ⇒ **没法回答「这个源在我这能不能用」**。
/// ⇒ 这里补上编排层（**纯 Foundation，沙盒 swiftc 能真编真跑** ✅）
///
/// ⚠️ **阶段失败不中断后面的阶段**（跟栖阅一样）：
///   目录挂了也照样把正文试一遍 ⇒ 一次测完就知道「哪些能用哪些不能用」。
struct SourceTestReport {
    /// 一个阶段的结果
    struct Stage: Identifiable {
        enum Kind: String, CaseIterable {
            case discover, detail, toc, content
            var title: String {
                switch self {
                case .discover: return "发现功能"
                case .detail: return "书籍详情"
                case .toc: return "目录列表"
                case .content: return "正文内容"
                }
            }
            var icon: String {
                switch self {
                case .discover: return "magnifyingglass"
                case .detail: return "doc.text"
                case .toc: return "list.bullet"
                case .content: return "text.alignleft"
                }
            }
        }
        let id = UUID()
        var kind: Kind
        var ok: Bool = false
        var ms: Int = 0
        /// 一句话摘要（栖阅那种「共 53 章」「3582 字」）
        var summary: String = ""
        /// 失败原因
        var error: String = ""
        /// 这一阶段用到的书（详情之后才有）
        var book: Book?
        /// 这一阶段用到的章节
        var chapter: Chapter?
    }

    var stages: [Stage] = []
    var sourceName: String = ""
    var sourceURL: String = ""
    var startedAt: Date = Date()

    var passed: Int { stages.filter { $0.ok }.count }
    var failed: Int { stages.filter { !$0.ok }.count }
    var totalMS: Int { stages.reduce(0) { $0 + $1.ms } }
    /// 「通过 4 · 失败 0」——栖阅那个顶部摘要
    var headLine: String { "通过 \(passed) · 失败 \(failed) · 耗时 \(fmtMS(totalMS))" }

    static func fmtMS(_ ms: Int) -> String {
        ms < 1000 ? "\(ms)ms" : String(format: "%.2fs", Double(ms) / 1000.0)
    }

    /// **复制测试报告**（栖阅面板的「复制测试报告」）
    var reportText: String {
        var lines: [String] = []
        lines.append("======== 轻阅 测书源报告 ========")
        lines.append("书源：\(sourceName)")
        lines.append("地址：\(sourceURL)")
        lines.append("时间：\(DateFormatter.localizedString(from: startedAt, dateStyle: .medium, timeStyle: .medium))")
        lines.append("结果：\(headLine)")
        lines.append("")
        for s in stages {
            lines.append("\(s.ok ? "✅" : "❌") \(s.kind.title)　\(SourceTestReport.fmtMS(s.ms))"
                + (s.ok ? "　\(s.summary)" : "　\(s.error)"))
        }
        lines.append("")
        lines.append("—— 引擎日志 ——")
        lines.append(RuleSandbox.shared.fullLogText())
        return lines.joined(separator: "\n")
    }
}

/// **测书源的编排器**
enum SourceTestRunner {
    /// 跑完整链路：发现 → 详情 → 目录 → 正文
    ///
    /// ⚠️ 每一步都**独立计时**、**失败不中断** ⇒ 一次跑完就知道哪个环节能用。
    static func run(_ source: BookSource,
                    service: SourceService = .shared) async -> SourceTestReport {
        var report = SourceTestReport()
        report.sourceName = source.name
        report.sourceURL = source.bookSourceUrl

        // ── ① 发现：先试发现页（explore），不行再回落搜索 ────────────
        var book: Book?
        var stage = SourceTestReport.Stage(kind: .discover)
        let t0 = Date()
        do {
            var books: [Book] = []
            var how = ""
            let kinds = try await service.exploreKinds(source: source)
            if let k = kinds.first(where: { !$0.url.isEmpty }) {
                books = try await service.explore(source: source, kindUrl: k.url, page: 1)
                how = "发现页「\(k.title.isEmpty ? k.url : k.title)」"
            }
            if books.isEmpty {
                books = try await service.search(source: source, keyword: "都市", page: 1)
                how = "搜索「都市」"
            }
            stage.ms = Int(Date().timeIntervalSince(t0) * 1000)
            if books.isEmpty {
                stage.error = "没找到书（\(how) 返回 0 本）"
            } else {
                stage.ok = true
                stage.summary = "\(books.count) 本书　来源：\(how)"
                book = books.first
                stage.book = book
            }
        } catch {
            stage.ms = Int(Date().timeIntervalSince(t0) * 1000)
            stage.error = Self.short(error)
        }
        report.stages.append(stage)
        // ⚠️ `guard var b = book` 会让 b **保持 Optional** ⇒ 后面 `b.bookUrl` 编译不过
        //    ⇒ 必须先解包再声明成非 Optional 的 var（详情阶段会更新它）
        guard let first = book else { return report }   // 没有书，后面三步没法测
        var b = first

        // ── ② 详情 ────────────────────────────────────────────────────
        var st2 = SourceTestReport.Stage(kind: .detail)
        let t1 = Date()
        do {
            let info = try await service.bookInfo(source: source, bookUrl: b.bookUrl, fallback: b)
            st2.ms = Int(Date().timeIntervalSince(t1) * 1000)
            st2.ok = true
            let author = info.author.isEmpty ? "未知" : info.author
            st2.summary = "《\(info.name)》　作者：\(author)"
            if !info.lastChapter.isEmpty { st2.summary += "　最新：\(info.lastChapter)" }
            // ⚠️ 详情可能带来新的 tocUrl ⇒ 后面用详情的结果
            b = info
            st2.book = b
        } catch {
            st2.ms = Int(Date().timeIntervalSince(t1) * 1000)
            st2.error = Self.short(error)
        }
        report.stages.append(st2)

        // ── ③ 目录 ────────────────────────────────────────────────────
        var st3 = SourceTestReport.Stage(kind: .toc)
        let t2 = Date()
        var chapters: [Chapter] = []
        do {
            let tocURL = b.tocUrl.isEmpty ? b.bookUrl : b.tocUrl
            chapters = try await service.toc(source: source, tocUrl: tocURL,
                                              bookUrl: b.bookUrl, book: b)
            st3.ms = Int(Date().timeIntervalSince(t2) * 1000)
            if chapters.isEmpty {
                st3.error = "目录 0 章（URL：\(Self.shorten(tocURL, 80))）"
            } else {
                st3.ok = true
                st3.summary = "共 \(chapters.count) 章"
                st3.book = b
            }
        } catch {
            st3.ms = Int(Date().timeIntervalSince(t2) * 1000)
            st3.error = Self.short(error)
        }
        report.stages.append(st3)

        // ── ④ 正文 ────────────────────────────────────────────────────
        var st4 = SourceTestReport.Stage(kind: .content)
        let t3 = Date()
        do {
            guard let ch = chapters.first(where: { !$0.isVolume }) ?? chapters.first else {
                st4.ms = Int(Date().timeIntervalSince(t3) * 1000)
                st4.error = "没有章节可取正文"
                report.stages.append(st4)
                return report
            }
            let c = try await service.content(source: source, chapter: ch, book: b)
            st4.ms = Int(Date().timeIntervalSince(t3) * 1000)
            let n = c.content.count
            if n == 0 {
                st4.error = "正文是空的"
            } else {
                st4.ok = true
                st4.summary = "\(n) 字　《\(c.title.isEmpty ? ch.title : c.title)》"
                st4.chapter = ch
                st4.book = b
            }
        } catch {
            st4.ms = Int(Date().timeIntervalSince(t3) * 1000)
            st4.error = Self.short(error)
        }
        report.stages.append(st4)

        return report
    }

    /// 错误压成一行（栖阅的诊断也这样，否则面板全是长堆栈）
    private static func short(_ e: Error) -> String {
        var s = String(describing: e)
        if let t = s.range(of: "\n") { s = String(s[s.startIndex..<t.lowerBound]) }
        return shorten(s, 160)
    }

    private static func shorten(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "…"
    }
}
