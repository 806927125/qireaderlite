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

    /// ⚠️⚠️ **全平铺，不分组**（2026-10-22 用户对照栖阅截图）
    ///
    /// 栖阅的「分类筛选」页是**一个卡片 + 全部分类平铺**（326 个一起），
    /// 而轻阅原来分成「分类 / 排行榜 / 热门标签 / 主题」四张卡片
    /// ⇒ 用户反馈「**分类排版不对**」
    ///
    /// 站方（🍅大灰狼）返回的分类里 **`group` 字段是空的**，
    /// 那些「排行榜 / 热门标签 / 主题」是引擎从 exploreUrl 的**装饰行**推出来的
    /// ⇒ 也就是说**分组是我们自己加的**，站方并没有这层结构 ⭐
    /// ⇒ 按栖阅：**一个网格，全平铺**
    ///
    /// ⚠️ 装饰行（`○ *。☆ 排行榜 ☆*。* ○` 那种）**不显示** ——
    ///    引擎已经把它们当组标题、不放进 kinds 了 ⇒ 这里天然不会出现。
    private var shown: [SourceService.KindDTO] {
        let list = kinds.filter { !isActionItem($0) }
        guard !search.isEmpty else { return list }
        let kw = search.lowercased()
        return list.filter { $0.title.lowercased().contains(kw) }
    }

    /// **动作项**（不是分类）—— 站方塞进来的个人书架/登录入口
    ///
    /// ⚠️ 栖阅那页也**没有**这些（第一个就是「推荐榜」）⇒ 同样过滤掉 ⭐
    /// ⚠️ 「未分组」是轻阅自己造的分组名，也一并去掉
    private func isActionItem(_ k: SourceService.KindDTO) -> Bool {
        let t = k.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        if t == "未分组" || t == "全部分类" { return true }
        // ⚠️ 「推荐榜」是**真分类**（栖阅那页第一个就是它）⇒ 绝不能过滤
        let actionWords = ["个人中心", "登录", "书架", "历史阅读", "个性推荐"]
        return actionWords.contains { t.contains($0) }
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
                        // ⭐ **一个卡片 + 全部分类平铺**（栖阅同款，2026-10-22）
                        VStack(alignment: .leading, spacing: 10) {
                            Text("分类")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.sub)
                                .padding(.leading, 4)

                            // 网格：栖阅是每行 4 个的那种排布
                            LazyVGrid(
                                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                                spacing: 8
                            ) {
                                ForEach(Array(shown.enumerated()), id: \.offset) { _, k in
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
                .padding(.horizontal, 14)
                .padding(.bottom, 24)
            }
        }
        .navigationBarBackButtonHidden(true)
    }
}
