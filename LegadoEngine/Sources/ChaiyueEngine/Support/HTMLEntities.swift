import Foundation
import SwiftSoup

enum HTMLEntities {
    /// HTML 实体反转义，失败时返回原文
    static func unescape(_ text: String) -> String {
        (try? Entities.unescape(text)) ?? text
    }
}
