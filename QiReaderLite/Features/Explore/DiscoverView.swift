import SwiftUI

/// 发现页 —— 照栖阅的信息架构：先列书源，点进去才是那个书源的榜单。
///
/// 之前我直接把榜单列表放在这一层，顶栏让用户用 SourcePicker 切书源，
/// 跟栖阅完全不是一回事（栖阅是两级：书源列表 → 某个书源的榜单）。
/// 现在改成：
///   发现（书源列表，卡片式）
///    └─ 点卡片 → ExploreView(source:)（书源名 + 分类胶囊 + 榜单列表）
///          └─ 点分类胶囊 → CategoryPickerView（分类筛选页）
struct DiscoverView: View {
    @EnvironmentObject private var store: SourceStore
    @State private var search = ""

    /// 只列「启用 + 有发现页」的源 —— 不能点的源摆在这儿没意义
    private var usable: [BookSource] {
        let list = store.enabled.filter { $0.exploreUrl != nil }
        guard !search.isEmpty else { return list }
        return list.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.bookSourceGroup.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        ZStack {
            PageBackdrop()

            ScrollView {
                VStack(spacing: 12) {
                    BigTitle("发现",
                              subtitle: "挑一个书源，看它的榜单")

                    if usable.isEmpty {
                        EmptyHint(icon: "safari",
                                  title: search.isEmpty ? "还没有可用的书源" : "没匹配到书源",
                                  subtitle: search.isEmpty
                                    ? "书源要先在「设置 → 书源」里导入并启用，还要带发现页"
                                    : "")
                            .padding(.top, 60)
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(usable) { s in
                                NavigationLink {
                                    ExploreView(source: s)
                                } label: {
                                    SourceCard(source: s)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 24)
            }
        }
        .searchable(text: $search, prompt: "搜书源名 / 分组")
    }
}

/// 书源卡片 —— 栖阅那套：彩色方块 + 名字 + 副标题 + 右侧 chevron
struct SourceCard: View {
    let source: BookSource

    var body: some View {
        HStack(spacing: 12) {
            SourceBadge(source: source, size: 50)

            VStack(alignment: .leading, spacing: 4) {
                Text(source.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(hostOf)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.sub.opacity(0.85))
                        .lineLimit(1)
                    PillTag(text: "看榜单", color: Theme.accent)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.sub.opacity(0.5))
        }
        .padding(12)
        .glassCard(cornerRadius: 18)
        .contentShape(Rectangle())
    }

    private var hostOf: String {
        if let h = source.sourceIconURL,
           let host = URL(string: h)?.host { return host }
        return URL(string: source.bookSourceUrl)?.host ?? source.bookSourceName
    }
}
