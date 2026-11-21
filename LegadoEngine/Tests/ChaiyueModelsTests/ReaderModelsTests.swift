import Foundation
import ChaiyueModels
import Testing

@Suite("数据模型")
struct ReaderModelsTests {
    @Test func lenientBookSourceDecoding() throws {
        let json = #"""
        [{"bookSourceUrl":"https://a.com","bookSourceName":"甲","bookSourceType":"0","enabled":"true",
          "ruleSearch":"{\"bookList\":\"class.item\",\"name\":\"tag.a@text\"}","customField":123},
         {"bookSourceName":"缺少地址"}]
        """#
        let sources = try SourceImport.bookSources(from: Data(json.utf8))
        #expect(sources.count == 1)
        let s = try #require(sources.first)
        #expect(s.bookSourceType == 0)
        #expect(s.enabled)
        #expect(s.searchRule.bookList == "class.item")
        #expect(s.extras["customField"] != nil)
    }

    @Test func bookSourceRoundTripKeepsUnknownFields() throws {
        let json = #"{"bookSourceUrl":"https://a.com","bookSourceName":"甲","ruleBookInfo":{"init":"@js:1","x":"y"},"weird":[1,2]}"#
        let source = try #require(try SourceImport.bookSources(from: Data(json.utf8)).first)
        #expect(source.bookInfoRule.initRule == "@js:1")
        let data = try JSONEncoder().encode(source)
        let again = try JSONDecoder().decode(BookSource.self, from: data)
        #expect(again == source)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"weird\""))
        #expect(text.contains("\"init\""))
    }

    @Test func bookVariablesAndChapterAliases() throws {
        var book = Book(bookUrl: "https://a.com/b/1", origin: "https://a.com", name: "书")
        book.customVariable = "abc"
        book.variableMap["k"] = "v"
        let decoded = try JSONDecoder().decode(Book.self, from: try JSONEncoder().encode(book))
        #expect(decoded.variableMap == ["custom": "abc", "k": "v"])

        let chapter = try JSONDecoder().decode(BookChapter.self, from: Data(#"{"name":"第一章","url":"/c/1","index":"3"}"#.utf8))
        #expect(chapter.title == "第一章")
        #expect(chapter.index == 3)
    }

    @Test func replaceRuleStringIdIsStable() throws {
        let json = #"[{"id":"abc","name":"去广告","pattern":"广告","replacement":"","isRegex":true}]"#
        let a = try SourceImport.replaceRules(from: Data(json.utf8))
        let b = try SourceImport.replaceRules(from: Data(json.utf8))
        #expect(a.first?.id == b.first?.id)
    }
}
