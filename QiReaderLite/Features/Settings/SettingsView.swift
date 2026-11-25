import SwiftUI

/// ⭐⭐⭐⭐⭐ **设置入口页**（柴阅式）⭐⭐⭐⭐⭐
///
/// 柴阅的设置区 = **一页一个独立子页**（About / Backup / Cache / Fonts /
/// ReaderThemes / ReadingSettings / SpeechSettings）⇒ 轻阅照抄这个结构，
/// 子页在 `SettingsScreens.swift`。
///
/// ⚠️ 这里**只做入口**：排版细项在「阅读设置」页、配色在「阅读主题」页 ——
///    （原来它们塞在阅读页的**栖阅面板**里，本轮已按柴阅的位置搬走）⭐⭐⭐
///
/// 从 Info.plist 的 CFBundleVersion 读 build 号（CI 注入的 CURRENT_PROJECT_VERSION）。
enum AppBuildInfo {
    /// CI 注入的 CURRENT_PROJECT_VERSION（拼在 CFBundleVersion 里）
    static let number: String = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
}

struct SettingsView: View {
    @EnvironmentObject private var store: SourceStore
    @EnvironmentObject private var library: LibraryStore

    @AppStorage("reader.theme") private var themeKey: String = "paper"
    @AppStorage("reader.fontKey") private var fontKey: String = "system"
    /// 液态玻璃浓度 —— 跟阅读器「更多设置 → 玻璃通透度」**同一个 key**，两边实时同步。
    ///
    /// ⚠️ 为什么设置页也要放一份：
    ///    玻璃浓度影响的是**全站**（书架/发现/详情/阅读），
    ///    但滑块原来只藏在阅读器面板里 —— 站在发现页想调玻璃，
    ///    得先进一本书再翻到「更多设置」，绕得没法用。
    @AppStorage(GlassTintStore.key) private var glassTintPercent: Double = 45

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

                    // ⭐⭐⭐⭐⭐ **设置项 = 柴阅的「一页一个独立子页」** ⭐⭐⭐⭐⭐
                    //   柴阅：About / Backup / Cache / Fonts / ReaderThemes /
                    //        ReadingSettings / SpeechSettings
                    //   轻阅：阅读设置 / 阅读主题 / 字体 / 缓存 / 备份 / 关于
                    settingsGroup {
                        NavigationLink {
                            ReadingSettingsScreen()
                        } label: {
                            rowLabel("textformat.size", "阅读设置", "", Theme.tagBlue)
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            ReaderThemesScreen()
                        } label: {
                            rowLabel("paintpalette", "阅读主题", "\(ReaderTheme.all.first(where: { $0.key == themeKey })?.name ?? "")", Theme.tagPurple)
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            FontsScreen()
                        } label: {
                            rowLabel("character", "字体", ReaderFont.name(for: fontKey), Theme.tagGreen)
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            CacheScreen()
                        } label: {
                            rowLabel("externaldrive", "缓存", "", Theme.tagBlue)
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            BackupScreen()
                        } label: {
                            rowLabel("icloud", "备份", "", Theme.tagBlue)
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            AboutScreen()
                        } label: {
                            rowLabel("info.circle", "关于", "build \(AppBuildInfo.number)", Theme.tagPurple)
                        }
                        .buttonStyle(.plain)
                    }

                    // 外观：液态玻璃浓度（全局，跟阅读器里的滑块同一个 key）
                    settingsGroup {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                Image(systemName: "circle.lefthalf.filled")
                                    .font(.system(size: 17))
                                    .foregroundStyle(Theme.tagPurple)
                                    .frame(width: 26)
                                Text("玻璃通透度")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.ink)
                                Spacer()
                                Text("\(Int(glassTintPercent))")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Theme.accent)
                            }
                            Slider(value: $glassTintPercent, in: 0...100, step: 5)
                                .tint(Theme.accent)
                            Text("数值越大越不透明（玻璃越实、字越清楚）")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.sub)
                        }
                        .padding(.vertical, 4)
                    }

                    // ⭐ 把 **build 号**显示出来。
                    //    这轮来回里最大的坑是「用户装的到底是哪一版」——
                    //    build 107 之后又出了 108 / 109，拿旧版截图对栖阅
                    //    会白改好几轮。版本号摆在这儿，一眼就能确认。
                    Text("轻阅 Lite · iOS 26+ · build \(AppBuildInfo.number)")
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

/// 引擎版本号（2026-11-19：引擎整个换成 `LegadoEngine`）
enum EngineInfo {
    static let version = "LegadoEngine · Legado 3.0 语义（六阅 iOS 逆向重建）"
}
