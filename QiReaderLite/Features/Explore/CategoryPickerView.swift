import SwiftUI

/// 分类筛选页 —— 由榜单页导航栏右侧的分类胶囊 push 进来。
///
/// ⚠️ 之前它是 `.sheet` 弹窗 + 自定义头部（「× 关闭」胶囊 + 居中两行标题）。
///    跟 sheet 自带的顶部区域打架，看起来很挤，而且下半屏全是空白。
///    现在改成正常的 push 页面：系统返回键 + 导航栏标题，下面直接是搜索框和网格。
///
/// 栖阅的分类是分组网格（排行榜 / 情节主题…），
/// 一行横向滚动的胶囊条在分类一多时就藏起来找不着了 —— 这里用分组网格。
struct CategoryPickerView: View {
    let kinds: [SourceService.KindDTO]
    let current: SourceService.KindDTO?
    let onPick: (SourceService.KindDTO) -> Void

    @State private var search = ""

    /// 按**分组**归类（栖阅同款：`ExploreCategorySplit.groups()`）
    ///
    /// ⚠️ 2026-10-21 修：原来按 `style` 分组 ❗
    ///    但 🍅大灰狼的组标题是 exploreUrl 里那些**装饰行**
    ///    （`○ *。*☆ 排行榜 ☆*。* ○`）⇒ 引擎解析成 `group` 字段 ✅
    ///    ⇒ 不按 group 分组的话，所有分类会挤成一个「全部分类」，
    ///       栖阅那种「分类 / ☆排行榜☆ / ☆热门标签☆」的分组就出不来 ❗
    ///    （style 仍作兜底：有些站的 exploreUrl 走 style 字段）
    private var groups: [(String, [SourceService.KindDTO])] {
        var dict: [String: [SourceService.KindDTO]] = [:]
        for k in kinds {
            // ⚠️⚠️ **组名优先用 `group`（引擎从站方装饰行解析的），空了就叫「分类」**
            //   以前空的时候回落到 `style` ⇒ 界面上出现
            //   `{"layout_flexGrow":1,"layout_flexBasisPercent":0.25}` 这种**原始 JSON 标题** ❗
            //   （栖阅那页第一组就叫「分类」⇒ 这里跟它对齐）
            let key = k.group.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = key.isEmpty ? "分类" : key
            dict[name, default: []].append(k)
        }
        // 排序：「分类」排第一，其余按名字
        return dict
            .map { (name: $0.key, items: $0.value) }
            .sorted { $0.name == "分类" ? true : ($1.name == "分类" ? false : $0.name < $1.name) }
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
                                            // 父页负责 pop 回榜单（onPick 里置 showCategoryPicker = false）
                                            onPick(k)
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
