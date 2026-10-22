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
    /// 按**站方给的顺序**分组（栖阅同款，2026-10-22 对照栖阅截图）
    ///
    /// 站方 style_list 的原始数据里，**url 为空的行就是「组标题行」**：
    ///     [2] 当前为: QQ阅读 [小说]频道：男频   ← 组标题
    ///     [3..7] 今日必读/会员榜/…              ← 归它
    ///     [8] 分类                              ← 又一个组标题
    ///     [9..22] 玄幻/奇幻/…                   ← 归它
    /// 引擎已经把这些行解析进 `kind.group` 了 ⇒ 这里按 group 变化切组。
    ///
    /// ⚠️⚠️ **必须按站方出现顺序，不能按名字排序！**
    ///   栖阅那页是「分类 → 当前为: XX → 分类 → 图书」这种顺序（站方给的）
    ///   ⇒ 按名字排会把「当前为: XX」和「图书」打乱 ⇒ 顺序不对 ❗
    ///
    /// ⚠️ 组标题行之前的那些项（infoData 的「大灰狼个人中心」等）⇒ 落在兜底的「分类」组
    ///   ⇒ 跟栖阅一模一样（栖阅第一张卡片就叫「分类」，里面只有「大灰狼个人中心」）⭐
    private var groups: [(String, [SourceService.KindDTO])] {
        var out: [(String, [SourceService.KindDTO])] = []
        var current = "分类"          // 兜底组名（栖阅第一组就叫「分类」）
        for k in kinds {
            let g = k.group.trimmingCharacters(in: .whitespacesAndNewlines)
            if !g.isEmpty && g != current {
                current = g
                out.append((current, []))
            }
            if out.isEmpty { out.append((current, [])) }
            out[out.count - 1].1.append(k)
        }
        // ⚠️ 空组不显示（「--」这种垃圾组标题后面没内容 ⇒ 不该出一个空卡片）
        return out.filter { !$0.1.isEmpty }
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
