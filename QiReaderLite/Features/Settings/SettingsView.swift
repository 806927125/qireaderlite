import SwiftUI

/// 设置页 —— 照栖阅截图 5 还原。
/// 栖阅的分组式列表：会员中心卡片 → 配置/朗读/替换净化/目录规则 → 阅读设置/字体/预缓存 → 外观/统计
/// 轻阅还没有替换净化、目录规则、字体管理这些，先把**已有能力**摆出来，
/// 没做的做成灰态而不是弹「还没接」。
struct SettingsView: View {
    @EnvironmentObject private var store: SourceStore
    @EnvironmentObject private var library: LibraryStore

    @AppStorage("fontSize") private var fontSize: Double = 18
    @AppStorage("lineSpacing") private var lineSpacing: Double = 6

    var body: some View {
        ZStack {
            PageBackdrop()

            ScrollView {
                VStack(spacing: 14) {
                    BigTitle("设置")

                    // 概览卡：替代栖阅的「会员中心」，放真实数据
                    summaryCard

                    settingsGroup {
                        // 书源管理搬进设置（用户定的）：底栏四格是
                        // 书架 / 发现 / 搜索 / 设置，书源不占格子
                        NavigationLink {
                            SourcesView()
                        } label: {
                            rowLabel("slider.horizontal.3", "书源管理", "\(store.sources.count) 个", Theme.tagBlue)
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            BookshelfView()
                        } label: {
                            rowLabel("books.vertical", "书库", "\(library.items.count) 本", Theme.tagGreen)
                        }
                        .buttonStyle(.plain)
                    }

                    settingsGroup {
                        // 阅读设置：真的能改
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                Image(systemName: "textformat.size")
                                    .font(.system(size: 17))
                                    .foregroundStyle(Theme.tagBlue)
                                    .frame(width: 26)
                                Text("正文字号")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.ink)
                                Spacer()
                                Text("\(Int(fontSize))")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Theme.accent)
                            }
                            Slider(value: $fontSize, in: 12...28, step: 1)
                                .tint(Theme.accent)

                            HStack(spacing: 10) {
                                Image(systemName: "text.justify")
                                    .font(.system(size: 17))
                                    .foregroundStyle(Theme.tagGreen)
                                    .frame(width: 26)
                                Text("行间距")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.ink)
                                Spacer()
                                Text("\(Int(lineSpacing))")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Theme.accent)
                            }
                            Slider(value: $lineSpacing, in: 0...20, step: 1)
                                .tint(Theme.accent)
                        }
                        .padding(.vertical, 4)
                    }

                    // 引擎信息：让用户能自己确认装的是哪一版
                    settingsGroup {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 10) {
                                Image(systemName: "gearshape.2")
                                    .font(.system(size: 17))
                                    .foregroundStyle(Theme.tagPurple)
                                    .frame(width: 26)
                                Text("规则引擎")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.ink)
                                Spacer()
                                PillTag(text: "轻阅", color: Theme.accent, filled: true)
                            }
                            Text(EngineInfo.version)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.sub)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)
                    }

                    Text("轻阅 Lite · iOS 17+")
                        .font(.caption)
                        .foregroundStyle(Theme.sub)
                        .padding(.top, 6)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 28)
            }
        }
    }

    private var summaryCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 22))
                .foregroundStyle(Theme.accent)
                .frame(width: 52, height: 52)
                .background(Theme.accent.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("我的书库")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("在读 \(library.items.filter { $0.lastChapterIndex > 0 && !$0.finished }.count) 本 · 共 \(library.items.count) 本")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.sub)
            }
            Spacer()
        }
        .padding(14)
        .glassCard(cornerRadius: 18, strong: true)
    }

    /// 栖阅那种一叠圆角行
    @ViewBuilder
    private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, 14)
        .glassCard(cornerRadius: 16, strong: true)
    }

    /// 一行「图标 + 标题 + 右侧值 + chevron」，NavigationLink 和 Button 共用
    private func rowLabel(_ icon: String, _ title: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(tint)
                .frame(width: 26)
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(Theme.ink)
            Spacer()
            Text(value)
                .font(.system(size: 14))
                .foregroundStyle(Theme.sub)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.sub.opacity(0.6))
        }
        .padding(.vertical, 13)
    }
}

/// 引擎版本号（RuleSandbox 那边也有一份，这里只读）
enum EngineInfo {
    static let version = "2026.10.18-r14 · Packages / AES / MessageDigest 已就位"
}
