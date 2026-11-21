import Foundation
import ChaiyueModels
@testable import ChaiyueEngine

/// 按路由返回固定响应的模拟网络
final class MockTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) -> HTTPResponse?
    private let lock = NSLock()
    private var routes: [(String, Handler)] = []
    private(set) var requests: [HTTPRequest] = []

    func on(_ urlPrefix: String, _ handler: @escaping Handler) {
        lock.withLock { routes.append((urlPrefix, handler)) }
    }

    func on(_ urlPrefix: String, body: String, contentType: String = "text/html; charset=utf-8") {
        on(urlPrefix) { req in
            HTTPResponse(url: req.url, headers: ["Content-Type": contentType], body: Data(body.utf8))
        }
    }

    func send(_ request: HTTPRequest) throws -> HTTPResponse {
        let handlers = lock.withLock {
            requests.append(request)
            return routes
        }
        for (prefix, handler) in handlers.reversed() where request.url.hasPrefix(prefix) {
            if let res = handler(request) { return res }
        }
        return HTTPResponse(url: request.url, statusCode: 404, body: Data("not found".utf8))
    }

    var lastRequest: HTTPRequest? { lock.withLock { requests.last } }
}

func makeSource(_ json: String) throws -> BookSource {
    try SourceImport.bookSources(from: Data(json.utf8))[0]
}

func makeEnvironment(_ transport: HTTPTransport = MockTransport()) -> SourceEnvironment {
    SourceEnvironment(http: transport, store: MemoryKeyValueStore(), deviceID: "test-device")
}

/// 在测试中直接构造解析会话
func makeSession(_ source: BookSource, env: SourceEnvironment) -> RuleSession {
    RuleSession(source: SourceDescriptor(source), env: env)
}

let minimalSourceJSON = #"{"bookSourceUrl":"https://example.com","bookSourceName":"测试源"}"#
