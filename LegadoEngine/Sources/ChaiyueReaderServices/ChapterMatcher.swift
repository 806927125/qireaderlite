import Foundation
import ChaiyueModels

/// 目录变化（刷新目录、换源）后找回原来读到的章节，算法与 Legado `BookHelp.getDurChapter` 一致：
/// 在原位置前后 10 章内先按净化后的章节名相似度（Jaro-Winkler）匹配，相似度不足 0.96 再按章节序号匹配，都不行就保持原索引
public enum ChapterMatcher {
    public static func index(oldIndex: Int, oldTitle: String?, newChapters: [BookChapter], oldCount: Int = 0) -> Int {
        if oldIndex <= 0 { return 0 }
        if newChapters.isEmpty { return oldIndex }
        let oldNumber = chapterNumber(oldTitle)
        let oldName = pureName(oldTitle)
        let newCount = newChapters.count
        let scaled = oldCount == 0 ? oldIndex : oldIndex * oldCount / newCount
        let lower = max(0, min(oldIndex, scaled) - 10)
        let upper = min(newCount - 1, max(oldIndex, scaled) + 10)
        let window = lower <= upper ? Array(lower...upper) : []

        var similarity = 0.0
        var newIndex = 0
        var newNumber = 0
        if !oldName.isEmpty {
            for i in window {
                let score = jaroWinkler(oldName, pureName(newChapters[i].title))
                if score > similarity {
                    similarity = score
                    newIndex = i
                }
            }
        }
        if similarity < 0.96, oldNumber > 0 {
            for i in window {
                let number = chapterNumber(newChapters[i].title)
                if number == oldNumber {
                    newNumber = number
                    newIndex = i
                    break
                } else if abs(number - oldNumber) < abs(newNumber - oldNumber) {
                    newNumber = number
                    newIndex = i
                }
            }
        }
        if similarity > 0.96 || abs(newNumber - oldNumber) < 1 {
            return newIndex
        }
        return min(max(0, newCount - 1), oldIndex)
    }

    // MARK: - 章节序号与净化

    // 与 Java 正则的默认语义保持一致：\d、\w、\s 只匹配 ASCII
    private static let numeral = "0-9零〇一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟"
    private static let numberPattern1 = regex(".*?第([\(numeral)]+)[章节篇回集话]")
    private static let numberPattern2 = regex("^(?:[\(numeral)]+[,:、])*([\(numeral)]+)(?:[,:、]|\\.[^0-9])")
    private static let whitespace = regex("[ \\t\\n\\x0B\\f\\r]")
    private static let serialPrefix = regex(
        "^.*?第(?:[\(numeral)]+)[章节篇回集话](?!$)|^(?:[\(numeral)]+[,:、])*(?:[\(numeral)]+)(?:[,:、](?!$)|\\.(?=[^0-9]))"
    )
    private static let bracketed = regex(
        "(?!^)(?:[〖【《〔\\[{(][^〖【《〔\\[{()〕》】〗\\]}]+)?[)〕》】〗\\]}]$|^[〖【《〔\\[{(](?:[^〖【《〔\\[{()〕》】〗\\]}]+[〕》】〗\\]})])?(?!$)"
    )
    // 原版写的 \u20000 在 Java 与 ICU 中都按 \u2000 加字符 0 解析，这里保留同样的字符集
    private static let other = regex("[^a-zA-Z_0-9\\u4E00-\\u9FEF〇\\u3400-\\u4DBF\\u20000-\\u2A6DF\\u2A700-\\u2EBEF]")

    static func chapterNumber(_ title: String?) -> Int {
        guard let title else { return -1 }
        let text = replace(whitespace, in: fullToHalf(title), with: "")
        let range = NSRange(text.startIndex..., in: text)
        let match = numberPattern1.firstMatch(in: text, range: range) ?? numberPattern2.firstMatch(in: text, range: range)
        guard let match, let group = Range(match.range(at: 1), in: text) else { return -1 }
        return stringToInt(String(text[group]))
    }

    static func pureName(_ title: String?) -> String {
        guard let title else { return "" }
        var text = replace(whitespace, in: fullToHalf(title), with: "")
        text = replace(serialPrefix, in: text, with: "")
        text = replace(bracketed, in: text, with: "")
        return replace(other, in: text, with: "")
    }

    static func fullToHalf(_ text: String) -> String {
        String(decoding: text.utf16.map { unit -> UInt16 in
            if unit == 12288 { return 32 }
            if (65281...65374).contains(unit) { return unit - 65248 }
            return unit
        }, as: UTF16.self)
    }

    // MARK: - 中文数字（Legado StringUtils.stringToInt / chineseNumToInt）

    private static let digits: [Character: Int] = [
        "零": 0, "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "十": 10,
        "〇": 0, "壹": 1, "贰": 2, "叁": 3, "肆": 4, "伍": 5, "陆": 6, "柒": 7, "捌": 8, "玖": 9, "拾": 10,
        "两": 2, "百": 100, "佰": 100, "千": 1000, "仟": 1000, "万": 10000, "亿": 100_000_000,
    ]

    static func stringToInt(_ text: String) -> Int {
        let number = replace(whitespace, in: fullToHalf(text), with: "")
        if let value = Int(number), value <= Int(Int32.max) { return value }
        return chineseNumber(number)
    }

    static func chineseNumber(_ text: String) -> Int {
        let chars = Array(text)
        let simple = Set("〇零一二三四五六七八九壹贰叁肆伍陆柒捌玖")
        if chars.count > 1, chars.allSatisfy(simple.contains) {
            return Int(String(chars.compactMap { digits[$0].map(String.init) }.joined())) ?? -1
        }
        var result = 0
        var tmp = 0
        var billion = 0
        for (i, char) in chars.enumerated() {
            guard let value = digits[char] else { return -1 }
            if value == 100_000_000 {
                result += tmp
                result *= value
                billion = billion * 100_000_000 + result
                result = 0
                tmp = 0
            } else if value == 10000 {
                result += tmp
                result *= value
                tmp = 0
            } else if value >= 10 {
                if tmp == 0 { tmp = 1 }
                result += value * tmp
                tmp = 0
            } else if i >= 2, i == chars.count - 1, let previous = digits[chars[i - 1]], previous > 10 {
                tmp = value * previous / 10
            } else {
                tmp = tmp * 10 + value
            }
        }
        return result + tmp + billion
    }

    // MARK: - Jaro-Winkler（与 java-string-similarity 的实现一致，阈值 0.7，按 UTF-16 码元比较）

    static func jaroWinkler(_ s1: String, _ s2: String) -> Double {
        if s1 == s2 { return 1 }
        let a = Array(s1.utf16), b = Array(s2.utf16)
        let (longer, shorter) = a.count > b.count ? (a, b) : (b, a)
        let range = max(longer.count / 2 - 1, 0)
        var matchIndexes = [Int](repeating: -1, count: shorter.count)
        var matchFlags = [Bool](repeating: false, count: longer.count)
        var matches = 0
        for (mi, c1) in shorter.enumerated() {
            var xi = max(mi - range, 0)
            let xn = min(mi + range + 1, longer.count)
            while xi < xn {
                if !matchFlags[xi], c1 == longer[xi] {
                    matchIndexes[mi] = xi
                    matchFlags[xi] = true
                    matches += 1
                    break
                }
                xi += 1
            }
        }
        guard matches > 0 else { return 0 }
        let ms1 = shorter.indices.filter { matchIndexes[$0] != -1 }.map { shorter[$0] }
        let ms2 = longer.indices.filter { matchFlags[$0] }.map { longer[$0] }
        let transpositions = zip(ms1, ms2).filter { $0 != $1 }.count / 2
        var prefix = 0
        for mi in 0..<shorter.count {
            if a[mi] == b[mi] { prefix += 1 } else { break }
        }
        let m = Double(matches)
        let jaro = (m / Double(a.count) + m / Double(b.count) + (m - Double(transpositions)) / m) / 3
        guard jaro > 0.7 else { return jaro }
        return jaro + min(0.1, 1.0 / Double(longer.count)) * Double(prefix) * (1 - jaro)
    }

    // MARK: - 工具

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
