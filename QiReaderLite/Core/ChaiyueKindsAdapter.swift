import Foundation
import LegadoEngine

// ⭐⭐⭐⭐⭐ **柴阅的 `ExploreKind` ⇒ 轻阅 UI 的 `kinds` / `filters`**（2026-11-21 移植柴阅）
//
// ⚠️⚠️ **为什么要这一层**：
//   柴阅的 `exploreKinds()` 返回 `[ExploreKind]`（**权威实现** ⇒ 分类/筛选栏都对）⭐⭐⭐
//   而轻阅 UI 吃的是**自己的一套 DTO**（`SourceService.KindDTO` / `FilterDTO`）⭐⭐⭐
//   ⇒ UI **一行不改** ⇒ 必须有一层把柴阅的形态转成轻阅的形态 ⭐⭐⭐
//
// ⭐⭐⭐ **UI 需要的键**（`SourceService.KindDTO` / `FilterDTO`）：
//   · kind  = { title, url, style, group }⭐⭐⭐
//   · filter= { title, type, chars, default, paramKey, action }⭐⭐⭐
//
// ⭐⭐⭐ **`paramKey` 是轻阅独有的**：它是**源级变量名**（如 `find_source`）
//   ⇒ 站方 action 形如 `show(infoMap['平台'],'find_source')` ⇒ 变量名在第二个引号里⭐⭐⭐
//   ⇒ 复用旧归一化器里已验证过的抽取逻辑（`ExploreKindsNormalizer.filterParamKey`）⭐⭐⭐
enum ChaiyueKindsAdapter {
    /// ⭐⭐⭐ **转换结果**（键名与轻阅 UI 期望的完全一致）⭐⭐⭐
    struct Normalized {
        var kinds: [[String: Any]] = []
        var filters: [[String: Any]] = []
    }

    /// ⭐⭐⭐⭐⭐ **柴阅的 `[ExploreKind]` ⇒ 轻阅的 `kinds` / `filters`** ⭐⭐⭐
    ///
    /// ⚠️⚠️ **分组（group）的来源**：柴阅的 `ExploreKind` **没有分组字段**⭐⭐⭐
    ///   ⇒ 轻阅的 `group` 来自站方用「装饰行」当组标题（url 为空、只有 title）⭐⭐⭐
    ///   ⇒ 正解：**把最近一个「只有标题的项」当作后续项的分组**⭐⭐⭐
    ///   ⇒ ⚠️ 这与旧引擎 `ExploreKindsNormalizer` 的行为一致（UI 行为不变）⭐⭐⭐
    static func normalize(_ kinds: [LegadoEngineHost.Kind]) -> Normalized {
        var out = Normalized()
        var currentGroup = ""

        for k in kinds {
            let title = k.title
            let url = k.url ?? ""
            let type = k.type ?? "url"

            // ① **组标题**：没有 url、也不是筛选项 ⇒ 它是「装饰行」⇒ 只更新分组 ⭐⭐⭐
            if url.isEmpty && (type == "url" || type.isEmpty) {
                if !title.isEmpty { currentGroup = title }
                continue
            }

            // ② **筛选项**（type != url）⇒ 进 `filters`⭐⭐⭐
            if type != "url" {
                out.filters.append([
                    "title": title,
                    "type": type,
                    "chars": k.chars ?? [],
                    "default": k.defaultValue ?? "",
                    // ⭐⭐⭐ **paramKey**：从站方 action 里抠源级变量名 ⭐⭐⭐
                    "paramKey": k.action.map { ExploreKindsNormalizer.filterParamKey($0) } ?? "",
                    "action": k.action ?? "",
                ])
                continue
            }

            // ③ **分类**（有 url）⇒ 进 `kinds`⭐⭐⭐
            out.kinds.append([
                "title": title,
                "url": url,
                "style": styleString(k.style),
                "group": currentGroup,
            ])
        }
        return out
    }

    /// ⭐⭐⭐ **布局样式 ⇒ 字符串**（轻阅 UI 只吃字符串）⭐⭐⭐
    private static func styleString(_ style: LegadoEngineHost.Kind.Style?) -> String {
        guard let style else { return "" }
        // ⚠️ 柴阅的 `Style` 是 Flexbox 结构 ⇒ 轻阅 UI 只用字符串 ⇒ 拼成 `key=value;` 形态 ⭐⭐⭐
        var parts: [String] = []
        if style.layoutFlexGrow != 1 { parts.append("layoutFlexGrow=\(style.layoutFlexGrow)") }
        if style.layoutFlexShrink != 1 { parts.append("layoutFlexShrink=\(style.layoutFlexShrink)") }
        if style.layoutAlignSelf != "auto" { parts.append("layoutAlignSelf=\(style.layoutAlignSelf)") }
        return parts.joined(separator: ";")
    }
}
