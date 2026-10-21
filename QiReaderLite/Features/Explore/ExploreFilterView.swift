import SwiftUI

/// **发现页筛选栏**（站方 exploreUrl 的 `type:"select"` 契约）
///
/// ⚠️ 为什么要有这个（2026-10-21 用户反馈「分类不应该有 api 的吗」）：
///
/// 站方（🍅大灰狼聚合）的 `exploreUrl` 返回的不是纯分类列表，而是：
///     `qtsj.concat(infoData, groupDatas, style_list)`
/// 其中 `qtsj` 是**发现页筛选栏**（栖阅的契约）：
/// ```js
/// createFilter("平台", ["番茄","七猫","书旗","塔读",…42个], sources, "find_source", 1)
/// createFilter("模式", ["小说","听书","短剧","漫画"],       tab,      "find_tab",   0.33)
/// createFilter("频道", ["男频","女频"],                     source_type,"source_type",0.33)
/// // + 线路 / 字数 / 状态 / 排序（番茄+小说时才有）
/// ```
/// 契约形状：`{ title, type:"select", chars:[选项], default:当前值, action:"show(infoMap['平台'],'find_source')" }`
///
/// ⚠️ 这些项**没有 url** ⇒ 轻阅以前把它们当普通分类 ⇒ 出现在分类列表里但点不动
///    ⇒ 用户看到「平台」那几项**没有 api**。
///    现在引擎侧把它们分流成 `filters` ⇒ 这里渲染成可点的筛选项。
///
/// ⭐ **选中之后写的是源级变量**（`paramKey`，如 `find_source`）
///    ⇒ 站方 exploreUrl 重跑时 `getArguments(open_argument,'find_source')` 就读到新值
///    ⇒ **十几���平台终于能切了**。
struct ExploreFilterView: View {
    let filters: [SourceService.FilterDTO]
    /// paramKey → 当前值
    let current: [String: String]
    /// 选中某个值（paramKey, value）
    let onPick: (String, String) -> Void

    var body: some View {
        ZStack {
            PageBackdrop()

            ScrollView {
                VStack(spacing: 14) {
                    if filters.isEmpty {
                        EmptyHint(icon: "line.3.horizontal.decrease.circle",
                                  title: "这个书源没有筛选栏",
                                  subtitle: "")
                            .padding(.top, 40)
                    } else {
                        ForEach(filters) { f in
                            card(f)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 24)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func card(_ f: SourceService.FilterDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(f.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.sub)
                // ⭐ 当前值直接标出来（平台多的时候一眼知道自己在哪个平台）
                if let cur = current[f.paramKey], !cur.isEmpty {
                    Text("· \(cur)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                Spacer()
            }

            if f.chars.isEmpty {
                Text("（这个筛选项没有可选项）")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.sub)
            } else {
                // ⚠️ 「平台」有 42 个 ⇒ 用**自适应网格**（横向滚动会藏起来找不着）
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 84, maximum: 140), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(Array(f.chars.enumerated()), id: \.offset) { _, c in
                        let on = current[f.paramKey] == c
                        Button {
                            guard !f.paramKey.isEmpty else { return }
                            onPick(f.paramKey, c)
                        } label: {
                            Text(c)
                                .font(.system(size: 13))
                                .lineLimit(1)
                                .foregroundStyle(on ? .white : Theme.ink)
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)
                                .background(
                                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                                        .fill(on ? Theme.accent : Color.white.opacity(0.5))
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(f.paramKey.isEmpty)
                    }
                }
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 18)
    }
}
