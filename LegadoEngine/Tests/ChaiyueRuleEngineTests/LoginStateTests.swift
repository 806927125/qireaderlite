import Foundation
import ChaiyueModels
@testable import ChaiyueEngine
import Testing

/// 记录登录变化回调
private final class LoginEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String] = []
    var all: [String] { lock.withLock { keys } }
    func append(_ key: String) { lock.withLock { keys.append(key) } }
}

/// 仿大灰狼：login() 把凭证写进服务器 Cookie 并保存登录头与线路变量；发现页按 Cookie 决定显示个人中心还是登录入口
private let sourceKey = "大灰狼测试源"
private let server = "https://srv.test"

private func wolfLikeSource() throws -> BookSource {
    let login = """
    function login() {
        var info = source.getLoginInfoMap();
        cookie.setCookie('\(server)', 'qttoken=' + info.get('密钥') + ';deviceId=d');
        source.putLoginHeader(JSON.stringify({Authorization: 'k-' + info.get('密钥')}));
        source.setVariable(JSON.stringify({server: '\(server)'}));
    }
    function logout() { cookie.removeCookie('\(server)'); }
    """
    let explore = """
    @js:cookie.getCookie('\(server)') ? '个人中心::\(server)/get_book_shelf' : '登录::{{java.startBrowser("\(server)/login","登录")}}'
    """
    let json: [String: Any] = [
        "bookSourceUrl": sourceKey, "bookSourceName": "测试", "loginUrl": login, "exploreUrl": explore,
        "loginUi": #"[{"name":"密钥","type":"text"},{"name":"退出","type":"button","action":"logout()"}]"#,
    ]
    return try makeSource(String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self))
}

@Suite("登录状态共享")
struct LoginStateTests {
    @Test func 一处登录其它实例立即读到() async throws {
        let src = try wolfLikeSource()
        let env = makeEnvironment()
        try await WebBook(source: src, environment: env).login(formData: ["密钥": "fake-key"])

        let other = WebBook(source: src, environment: env)
        #expect(other.savedLoginInfo["密钥"] == "fake-key")
        #expect(other.loginHeader?.contains("k-fake-key") == true)
        #expect(env.cookies.getKey(url: server, key: "qttoken") == "fake-key")
        #expect(try await other.evalJS("source.getLoginInfoMap().get('密钥')") == "fake-key")
        #expect(try await other.evalJS("cookie.getKey('\(server)/user_api', 'qttoken')") == "fake-key")
        #expect(try await other.evalJS("JSON.parse(source.getVariable()).server") == server)
    }

    @Test func 写盘后重新打开仍是登录状态() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("login-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let src = try wolfLikeSource()
        let store = FileKeyValueStore(fileURL: file)
        let env = SourceEnvironment(http: MockTransport(), store: store, deviceID: "test-device")
        try await WebBook(source: src, environment: env).login(formData: ["密钥": "fake-key"])
        store.flush()

        let reopened = SourceEnvironment(http: MockTransport(), store: FileKeyValueStore(fileURL: file), deviceID: "test-device")
        let web = WebBook(source: src, environment: reopened)
        #expect(web.savedLoginInfo["密钥"] == "fake-key")
        #expect(web.loginHeader != nil)
        #expect(reopened.cookies.getKey(url: server, key: "qttoken") == "fake-key")
        #expect(reopened.loginStamp(sourceKey) == env.loginStamp(sourceKey))
    }

    @Test func 登录与退出都会通知() async throws {
        let src = try wolfLikeSource()
        let env = makeEnvironment()
        let events = LoginEvents()
        env.setLoginChangeHandler { events.append($0) }
        let web = WebBook(source: src, environment: env)

        let before = env.loginStamp(sourceKey)
        try await web.login(formData: ["密钥": "fake-key"])
        #expect(events.all == [sourceKey])
        let afterLogin = env.loginStamp(sourceKey)
        #expect(afterLogin != before)

        // 退出只删 Cookie，不动登录信息
        try await web.runLoginAction("logout()", formData: web.savedLoginInfo)
        #expect(events.all.count == 2)
        #expect(env.loginStamp(sourceKey) != afterLogin)

        // 只读不写不算变化；详情、阅读等入口的脚本写登录头也算
        _ = try await web.evalJS("source.getLoginHeader(); cookie.getCookie('\(server)')")
        #expect(events.all.count == 2)
        _ = try await web.evalJS("source.putLoginHeader('{\"t\":\"2\"}')")
        #expect(events.all.count == 3)
    }

    @Test func 发现页分类随登录状态更新() async throws {
        let src = try wolfLikeSource()
        let env = makeEnvironment()
        let explore = WebBook(source: src, environment: env)
        #expect(try await explore.exploreKinds().map(\.title) == ["登录"])

        // 不经过登录直接改 Cookie 时沿用缓存
        env.cookies.setCookie(url: server, cookie: "x=1")
        #expect(try await explore.exploreKinds().map(\.title) == ["登录"])
        env.cookies.removeCookie(url: server)

        try await WebBook(source: src, environment: env).login(formData: ["密钥": "fake-key"])
        let kinds = try await WebBook(source: src, environment: env).exploreKinds()
        #expect(kinds.map(\.title) == ["个人中心"])

        try await explore.runLoginAction("logout()", formData: [:])
        #expect(try await explore.exploreKinds().map(\.title) == ["登录"])
    }

    @Test func 旧版缓存失效且生成分类不触发登录通知() async throws {
        let src = try wolfLikeSource()
        let env = makeEnvironment()
        let exploreUrl = try #require(src.exploreUrl)
        let cacheKey = "exploreKinds_" + Hex.encode(Digests.digest("MD5", Data((src.bookSourceUrl + exploreUrl).utf8)) ?? Data())
        env.cache.put(cacheKey, "旧条目::\(server)/old")
        env.cookies.setCookie(url: server, cookie: "qttoken=fake-key")
        #expect(try await WebBook(source: src, environment: env).exploreKinds().map(\.title) == ["个人中心"])

        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(src)) as? [String: Any] ?? [:]
        json["exploreUrl"] = "@js:source.putLoginInfo('{\"a\":\"1\"}'); '分类::/a'"
        let writer = try makeSource(String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self))
        let events = LoginEvents()
        env.setLoginChangeHandler { events.append($0) }
        #expect(try await WebBook(source: writer, environment: env).exploreKinds(refresh: true).map(\.title) == ["分类"])
        #expect(events.all.isEmpty)
    }
}
