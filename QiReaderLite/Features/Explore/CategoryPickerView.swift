import SwiftUI

/// 分类筛选 —— 照栖阅第 2 张图。
/// 顶栏：左侧「× 关闭」胶囊 + 居中标题「分类筛选」+ 当前分类副标题
/// 下面：搜索框（搜分类标签）+ 按 style 分组的胶囊网格
///
/// 栖阅的分类是分组网格（排行榜 / 情节主题…），
/// 我之前用一行横向滚动的胶囊条，分类一多就藏起来找不着了 —— 这里换成分组网格。
struct CategoryPickerView: View {
    let source: BookSource
    let kinds: [SourceService.KindDTO]
    let current: SourceService.KindDTO?
    let onPick: (SourceService.KindDTO) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    /// 按 style 分组。style 为空的一律归到「其他」——
    /// 不少站的 exploreUrl 不带分组，硬按空串分组会显示成一个空标题。
    private var groups: [(String, [SourceService.KindDTO])] {
        var dict: [String: [SourceService.KindDTO]] = [:]
        for k in kinds {
            let key = k.style.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = key.isEmpty ? "全部分类" : key
            dict[name, default: []].append(k)
        }
        return dict
            .map { (name: $0.key, items: $0.value) }
            .sorted { $0.name == "全部分类" ? true : ($1.name == "全部分类" ? false : $0.name < $1.name) }
    }

    private var shown: [(String, [SourceService.KindDTO])] {
        guard !search.isEmpty else { return groups }
        let kw = search.lowercased()
        return groups.compactMap { name, items in
            let hit = items.filter { $0.title.lowercased().contains(kw) }
            return hit.isEmpty ? nil : (name, hit)
        }
    }

    var body: some View {
        ZStack {
            PageBackdrop()

            ScrollView {
                VStack(spacing: 14) {
                    // 顶栏：栖阅是「× 关闭」在左，标题居中
                    HStack {
                        Button { dismiss() } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 12, weight: .bold))
                                Text("关闭")
                                    .font(.system(size: 14, weight: .medium))
                            }
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .liquidGlass(cornerRadius: 999)
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        VStack(spacing: 1) {
                            Text("分类筛选")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                            if let c = current, !c.title.isEmpty {
                                Text("当前 · \(c.title)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.sub)
                            }
                        }

                        Spacer()
                        // 占位，让标题真居中
                        Color.clear.frame(width: 62, height: 1)
                    }

                    // 搜索框
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.sub)
                        TextField("搜索这个页面的分类标签", text: $search)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.ink)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .liquidGlass(cornerRadius: 999)

                    if shown.isEmpty {
                        EmptyHint(icon: "line.3.horizontal.decrease.circle",
                                  title: search.isEmpty ? "这个书源没有分类" : "没匹配到分类",
                                  subtitle: "")
                            .padding(.top, 40)
                    } else {
                        // ⚠️ ForEach 的元素是元组，元组没有 .name 成员属性，
                        //    得先解构成局部常量再用（下面 groupTitle / groupItems）。
                        ForEach(Array(shown.enumerated()), id: \.offset) { _, entry in
                            let groupTitle = entry.0
                            let groupItems = entry.1
                            VStack(alignment: .leading, spacing: 10) {
                                Text(groupTitle)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Theme.sub)
                                    .padding(.leading, 4)

                                // 网格：栖阅是每行 4 个的那种排布
                                LazyVGrid(
                                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                                    spacing: 8
                                ) {
                                    ForEach(Array(groupItems.enumerated()), id: \.offset) { _, k in
                                        let on = current?.url == k.url
                                        Button {
                                            onPick(k)
                                            dismiss()
                                        } label: {
                                            Text(k.title)
                                                .font(.system(size: 13))
                                                .lineLimit(1)
                                                .foregroundStyle(on ? .white : Theme.ink)
                                                .frame(maxWidth: .infinity)
                                                .frame(height: 38)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                                                        .fill(on ? Theme.accent : Color.white.opacity(0.5))
                                                )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .padding(14)
                            .glassCard(cornerRadius: 18)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 24)
            }
        }
        .navigationBarBackButtonHidden(true)
    }
}
