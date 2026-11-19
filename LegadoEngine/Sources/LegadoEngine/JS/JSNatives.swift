#if canImport(JavaScriptCore) && !os(Linux)
import Foundation
import JavaScriptCore
import SwiftSoup
import CommonCrypto
import Crypto
import Security
import Compression

// MARK: - 原生分发（java.* / cookie.* / __native.*）
// 字节数组约定：JS 侧为有符号数字数组（-128…127），与提取的 bootstrap 注释一致。
extension JSBridge {

    func dispatch(_ name: String, _ a: [Any]) -> Any? {
        switch name {

        // ---- java 基础 ----
        case "log": host?.jsLog(str(a, 0) ?? "null"); return nil
        case "toast", "longToast": host?.jsToast(str(a, 0) ?? "null"); return nil
        case "ajax": return httpDict(a)?.body
        case "__connect": return httpDict(a)?.jsDict
        case "__http": return httpDict(a)?.jsDict
        case "jHttp": return httpDict(a)?.jsDict
        case "__get": return variables.get(str(a, 0) ?? "")
        case "__put": variables.put(str(a, 0) ?? "", str(a, 1) ?? ""); return nil
        case "__crypto": return nCrypto(a)
        case "base64Encode":
            guard let s = str(a, 0) else { return nil }
            var out = Data(s.utf8).base64EncodedString()
            if let f = num(a, 1) {
                if Int(f) & 8 != 0 { out = out.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_") }
                if Int(f) & 1 != 0 { out = out.replacingOccurrences(of: "=", with: "") }
            }
            return out
        case "base64DecodeToByteArray":
            guard let s = str(a, 0), let d = Self.decodeBase64(s) else { return nil }
            return Self.signedArray(d)
        case "base64Decode", "base64DecodeToString":
            guard let s = str(a, 0), let d = Self.decodeBase64(s) else { return nil }
            return String(data: d, encoding: .utf8) ?? ""
        case "md5Encode":
            guard let s = str(a, 0) else { return nil }
            return Self.digestHex("MD5", Data(s.utf8))
        case "md5Encode16":
            guard let s = str(a, 0) else { return nil }
            let h = Self.digestHex("MD5", Data(s.utf8))
            return String(h.dropFirst(8).prefix(16))
        case "strToBytes":
            guard let s = str(a, 0) else { return nil }
            let enc = HTTPClient.encoding(named: str(a, 1)) ?? .utf8
            return Self.signedArray(s.data(using: enc) ?? Data(s.utf8))
        case "bytesToStr":
            let d = Self.dataArg(a.first)
            let enc = HTTPClient.encoding(named: str(a, 1)) ?? .utf8
            return String(data: d, encoding: enc) ?? ""
        case "bytesToText":
            let d = Self.dataArg(a.first)
            let enc = HTTPClient.encoding(named: str(a, 1)) ?? .utf8
            return String(data: d, encoding: enc) ?? ""
        case "randomUUID": return UUID().uuidString.lowercased()
        case "androidId": return Self.androidId()
        case "encodeURI":
            guard let s = str(a, 0) else { return nil }
            return Self.formEncode(s, charset: str(a, 1))
        case "timeFormat": return Self.timeFormat(str(a, 0) ?? "yyyy/MM/dd HH:mm:ss", utc: false)
        case "timeFormatUTC": return Self.timeFormat(str(a, 0) ?? "yyyy/MM/dd HH:mm:ss", utc: true)
        case "appVersionName": return "1.0.7"
        case "appVersionCode": return 107
        case "webViewUA": return Self.defaultUA
        case "sleep":
            Thread.sleep(forTimeInterval: (num(a, 0) ?? 0) / 1000.0); return nil
        case "toURL": return nToURL(a)
        case "toNumChapter": return str(a, 0).map(Self.toNumChapter)
        case "utf8ToGbk":
            guard let s = str(a, 0) else { return nil }
            let enc = HTTPClient.encoding(named: "GBK") ?? .utf8
            return Self.signedArray(s.data(using: enc) ?? Data())
        case "getElement": return nil      // 需要当前 content，桥内不可得（stub）
        case "getElements": return []      // 同上

        // ---- cookie ----
        case "getCookie": return nGetCookie(a)
        case "setCookie": nSetCookie(a); return nil
        case "removeCookie": nRemoveCookie(a); return nil
        case "getKey": return str(a, 0) ?? source?.bookSourceUrl ?? ""
        case "cookieToMap": return Self.cookieToMap(str(a, 0) ?? "")
        case "cookieReplace":
            nRemoveCookie([str(a, 0) ?? ""]); nSetCookie(a); return nil
        case "cookieSetWeb": nSetCookie(a); return nil
        case "cookieClear":
            let st = HTTPCookieStorage.shared
            for c in st.cookies ?? [] { st.deleteCookie(c) }
            return nil

        // ---- 变量 / 书源信息 ----
        case "varGet": return variables.get(str(a, 0) ?? "")
        case "varPut": variables.put(str(a, 0) ?? "", str(a, 1) ?? ""); return nil
        case "srcGet":
            let k = str(a, 0) ?? ""
            if k == "__variable" { return source?.getVariable() ?? "" }
            return source?.getVariable(key: k) ?? ""
        case "srcPut":
            let k = str(a, 0) ?? ""
            if k == "__variable" { source?.setVariable(str(a, 1) ?? "") }
            else { source?.putVariable(key: k, value: str(a, 1) ?? "") }
            return nil
        case "loginInfoGet": return source?.getVariable(key: "loginInfo") ?? ""
        case "loginInfoPut": source?.putVariable(key: "loginInfo", value: str(a, 0) ?? ""); return nil
        case "loginInfoRemove": source?.putVariable(key: "loginInfo", value: ""); return nil
        case "loginHeaderGet": return source?.getVariable(key: "loginHeader") ?? ""
        case "loginHeaderPut": source?.putVariable(key: "loginHeader", value: str(a, 0) ?? ""); return nil
        case "loginHeaderRemove": source?.putVariable(key: "loginHeader", value: ""); return nil
        case "loginJs": return ""          // 登录 UI 流程不在引擎范围内（stub）
        case "infoMapGet": return Self.infoMap[str(a, 0) ?? ""]
        case "infoMapPut":
            let k = str(a, 0) ?? ""
            var m = Self.infoMap
            if let v = str(a, 1) { m[k] = v } else { m.removeValue(forKey: k) }
            Self.infoMap = m
            return nil
        case "infoMapAll":
            let m = Self.infoMap
            if let d = try? JSONSerialization.data(withJSONObject: m), let s = String(data: d, encoding: .utf8) { return s }
            return "{}"

        // ---- 缓存（cache.* / xc*）----
        case "xcPut": Self.cachePut(str(a, 0) ?? "", data: Data((str(a, 1) ?? "").utf8), deadline: num(a, 2) ?? 0); return nil
        case "xcPutBytes": Self.cachePut(str(a, 0) ?? "", data: Self.dataArg(a.count > 1 ? a[1] : nil), deadline: num(a, 2) ?? 0); return nil
        case "xcGet":
            guard let d = Self.cacheGet(str(a, 0) ?? "", onlyDisk: bool(a, 1)) else { return nil }
            return String(data: d, encoding: .utf8) ?? ""
        case "xcGetBytes":
            guard let d = Self.cacheGet(str(a, 0) ?? "", onlyDisk: false) else { return nil }
            return Self.signedArray(d)
        case "xcDel": Self.cacheDelete(str(a, 0) ?? ""); return nil
        case "xcMemPut": Self.memPut(str(a, 0) ?? "", str(a, 1) ?? ""); return nil
        case "xcMemGet": return Self.memGet(str(a, 0) ?? "")
        case "xcMemDel": Self.memDel(str(a, 0) ?? ""); return nil
        case "xcPutFile": return nPutFile(a)
        case "xcGetFile":
            let p = Self.cacheFilePath(str(a, 0) ?? "")
            return FileManager.default.fileExists(atPath: p) ? p : nil

        // ---- 文件 ----
        case "fileInfo": return nFileInfo(str(a, 0) ?? "")
        case "fileList": return nFileList(str(a, 0) ?? "")
        case "readFile":
            let p = Self.resolvePath(str(a, 0) ?? "")
            guard let d = FileManager.default.contents(atPath: p) else { return nil }
            return Self.signedArray(d)
        case "readTxtFile":
            let p = Self.resolvePath(str(a, 0) ?? "")
            guard let d = FileManager.default.contents(atPath: p) else { return nil }
            return HTTPClient.decode(d, charset: str(a, 1), contentType: nil)
        case "deleteFile":
            let p = Self.resolvePath(str(a, 0) ?? "")
            return (try? FileManager.default.removeItem(atPath: p)) != nil
        case "downloadFile": return nDownloadFile(a)
        case "getTxtInFolder": return nGetTxtInFolder(str(a, 0) ?? "")
        case "unArchiveFile", "zipBytes":
            host?.jsLog("LegadoEngine: 压缩文件操作未实现 (\(name))")
            return nil

        // ---- 摘要 / HMAC / CRC / 压缩 ----
        case "jDigest":
            let d = Self.dataArg(a.count > 1 ? a[1] : nil)
            guard let r = Self.digest(str(a, 0) ?? "MD5", d) else { jsThrow("未知摘要算法 \(str(a, 0) ?? "")"); return nil }
            return Self.signedArray(r)
        case "jHmac":
            let key = Self.dataArg(a.count > 1 ? a[1] : nil)
            let msg = Self.dataArg(a.count > 2 ? a[2] : nil)
            guard let r = Self.hmac(str(a, 0) ?? "HmacSHA256", key: key, msg: msg) else { jsThrow("未知 HMAC 算法 \(str(a, 0) ?? "")"); return nil }
            return Self.signedArray(r)
        case "jCrc32":
            var crc = UInt32(truncatingIfNeeded: Int64(num(a, 0) ?? 0))
            crc = Self.crc32(Self.dataArg(a.count > 1 ? a[1] : nil), seed: crc)
            return Int(Int32(bitPattern: crc))
        case "jGzip": return Self.signedArray(Self.gzip(Self.dataArg(a.first), compress: true))
        case "jGunzip": return Self.signedArray(Self.gzip(Self.dataArg(a.first), compress: false))
        case "jDeflate": return Self.signedArray(Self.deflate(Self.dataArg(a.first), compress: true, nowrap: bool(a, 1)))
        case "jInflate": return Self.signedArray(Self.deflate(Self.dataArg(a.first), compress: false, nowrap: bool(a, 1)))
        case "jRandomBytes":
            var d = Data(count: max(0, Int(num(a, 0) ?? 0)))
            _ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
            return Self.signedArray(d)
        case "b64Bytes": return Self.dataArg(a.first).base64EncodedString()
        case "hexBytes": return Self.dataArg(a.first).map { String(format: "%02x", $0) }.joined()

        // ---- 对称 / 非对称加密 ----
        case "jCipher": return nCipher(a)
        case "rsa": return nRSA(a)
        case "rsaGen": return nRSAGen()
        case "rsaKeyOut":
            guard let k = str(a, 0) else { return nil }
            if str(a, 2) == "bytes" { return Self.signedArray(Self.decodeBase64(k) ?? Data()) }
            return k
        case "rsaSign": return nRSASign(a)
        case "rsaVerify": return nRSAVerify(a)

        // ---- jsoup ----
        case "jsoupDoc": return nJsoupDoc(str(a, 0) ?? "", base: str(a, 1) ?? "")
        case "jsoupSelect": return nJsoupSelect(str(a, 0) ?? "", css: str(a, 1) ?? "", base: str(a, 3) ?? "")
        case "jsoupChildren": return nJsoupChildren(str(a, 0) ?? "")
        case "jsoupRemove": return nJsoupRemove(str(a, 0) ?? "", css: str(a, 1) ?? "", base: str(a, 3) ?? "")
        case "jsoupAbs": return NetworkUtils.absoluteURL(str(a, 0), str(a, 1) ?? "")

        // ---- bitmap / TTF / UI（stub，不崩）----
        case "bmpW", "bmpH": return 0
        case "bmpCreate", "bmpCrop", "bmpDecode", "bmpDraw", "bmpEncode", "bmpScale": return nil
        case "ttfMapGet": return nil
        case "ttfMapSize": return 0
        case "ttfCall": return nil
        case "ttfQuery": return nil
        case "ttfReplace": return str(a, 0)
        case "searchBook", "openUi", "startBrowser", "startBrowserAwait", "startBrowserTitled",
             "showBrowserHtml", "reLoginView", "exploreRefresh", "webView":
            host?.jsLog("LegadoEngine: UI 操作不在引擎范围内 (\(name))")
            return nil

        default:
            return nil
        }
    }

    // MARK: - HTTP（ajax / connect / __http / jHttp）

    struct NativeResponse {
        var body: String
        var jsDict: [String: Any]
    }

    func httpDict(_ a: [Any]) -> NativeResponse? {
        // 形态1: (url, headersJSON?)            —— java.__connect / ajax
        // 形态2: (method, url, body, headersObj) —— java.__http
        // 形态3: (url, method, headersObj, body, retry, follow) —— jHttp
        var method = "GET", urlStr = "", body: String? = nil
        var headers: [String: String] = [:]
        let first = str(a, 0) ?? ""
        if ["GET", "POST", "HEAD", "PUT", "DELETE", "OPTIONS", "PATCH", "TRACE"].contains(first.uppercased()) && a.count >= 2 {
            method = first.uppercased(); urlStr = str(a, 1) ?? ""
            body = str(a, 2)
            if let h = a.count > 3 ? a[3] : nil as Any? { headers = Self.headerMap(h) }
        } else if a.count >= 2, let m = str(a, 1), ["GET", "POST", "HEAD", "PUT", "DELETE", "OPTIONS", "PATCH"].contains(m.uppercased()) {
            urlStr = first; method = m.uppercased()
            if let h = a.count > 2 ? a[2] : nil as Any? { headers = Self.headerMap(h) }
            body = str(a, 3)
        } else {
            urlStr = first
            if let h = a.count > 1 ? a[1] : nil as Any? { headers = Self.headerMap(h) }
        }
        guard let url = URL(string: urlStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlStr)
                ?? URL(string: urlStr) else {
            jsThrow("MalformedURLException: \(urlStr)")
            return nil
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if req.value(forHTTPHeaderField: "User-Agent") == nil { req.setValue(Self.defaultUA, forHTTPHeaderField: "User-Agent") }
        if let b = body { req.httpBody = Data(b.utf8) }
        guard let resp = HTTPClient.shared.requestSync(req) else {
            jsThrow("请求失败: \(urlStr)")
            return nil
        }
        let dict: [String: Any] = [
            "body": resp.body, "code": resp.statusCode,
            "url": resp.url.absoluteString, "headers": resp.headers,
            "cookies": resp.cookies, "reqUrl": urlStr,
            "method": method, "reqHeaders": headers,
        ]
        return NativeResponse(body: resp.body, jsDict: dict)
    }

    static func headerMap(_ v: Any) -> [String: String] {
        var out: [String: String] = [:]
        if let s = v as? String {
            if let d = s.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                for (k, val) in obj { out[k] = "\(val)" }
            }
        } else if let dict = v as? [String: Any] {
            for (k, val) in dict { if !(val is NSNull) { out[k] = "\(val)" } }
        }
        return out
    }

    static let defaultUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    // MARK: - cookie

    func nGetCookie(_ a: [Any]) -> Any? {
        let tag = str(a, 0) ?? source?.bookSourceUrl ?? ""
        guard let url = Self.cookieURL(tag) else { return "" }
        let cs = HTTPCookieStorage.shared.cookies(for: url) ?? []
        if let key = str(a, 1) { return cs.first { $0.name == key }?.value ?? "" }
        return cs.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    func nSetCookie(_ a: [Any]) {
        let tag = str(a, 0) ?? source?.bookSourceUrl ?? ""
        guard let url = Self.cookieURL(tag), let host = url.host else { return }
        let raw = str(a, 1) ?? ""
        for part in raw.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, !kv[0].isEmpty else { continue }
            if ["path", "domain", "expires", "max-age", "secure", "httponly", "samesite"].contains(kv[0].lowercased()) { continue }
            if let c = HTTPCookie(properties: [.domain: host, .path: "/", .name: kv[0], .value: kv[1], .discard: "TRUE"]) {
                HTTPCookieStorage.shared.setCookie(c)
            }
        }
    }

    func nRemoveCookie(_ a: [Any]) {
        let tag = str(a, 0) ?? source?.bookSourceUrl ?? ""
        guard let url = Self.cookieURL(tag) else { return }
        let st = HTTPCookieStorage.shared
        for c in st.cookies(for: url) ?? [] { st.deleteCookie(c) }
    }

    static func cookieURL(_ tag: String) -> URL? {
        if let u = URL(string: tag), u.host != nil { return u }
        return URL(string: "https://" + tag)
    }

    static func cookieToMap(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in s.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    // MARK: - URL / 章节数字

    func nToURL(_ a: [Any]) -> Any? {
        let raw = str(a, 0) ?? ""
        let abs = NetworkUtils.absoluteURL(str(a, 1), raw)
        guard let u = URL(string: abs), let scheme = u.scheme, let host = u.host else { return nil }
        var params: [String: String] = [:]
        let comps = URLComponents(url: u, resolvingAgainstBaseURL: false)
        for item in comps?.queryItems ?? [] { params[item.name] = item.value ?? "" }
        let port = u.port.map { ":\($0)" } ?? ""
        return [
            "href": u.absoluteString,
            "protocol": scheme + ":",
            "host": host + port,
            "hostname": host,
            "port": u.port.map(String.init) ?? "",
            "origin": "\(scheme)://\(host)\(port)",
            "pathname": u.path.isEmpty ? "/" : u.path,
            "search": comps?.query.map { "?" + $0 } ?? "",
            "searchParams": params,
            "hash": u.fragment.map { "#" + $0 } ?? "",
        ] as [String: Any]
    }

    /// 中文字符章节号 → 阿拉伯数字（Legado toNumChapter）
    static func toNumChapter(_ s: String) -> String {
        let cn: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
                                    "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        let units: [Character: Int] = ["十": 10, "百": 100, "千": 1000]
        func convert(_ word: String) -> Int? {
            var total = 0, section = 0, digit = 0, has = false
            for ch in word {
                if let d = cn[ch] { digit = d; has = true }
                else if let u = units[ch] {
                    section += (digit == 0 ? 1 : digit) * u; digit = 0; has = true
                } else if ch == "万" {
                    total += (section + digit) * 10000; section = 0; digit = 0; has = true
                } else { return nil }
            }
            return has ? total + section + digit : nil
        }
        var out = ""
        var buf = ""
        func flush() {
            if buf.isEmpty { return }
            if let n = convert(buf) { out += String(n) } else { out += buf }
            buf = ""
        }
        for ch in s {
            if cn[ch] != nil || units[ch] != nil || ch == "万" { buf.append(ch) }
            else { flush(); out.append(ch) }
        }
        flush()
        return out
    }

    // MARK: - jsoup（SwiftSoup）

    static func elDict(_ el: Element) -> [String: Any] {
        var attrs: [String: String] = [:]
        for attr in el.getAttributes()?.asList() ?? [] { attrs[attr.getKey()] = attr.getValue() }
        return [
            "tag": el.tagName(),
            "attrs": attrs,
            "text": (try? el.text()) ?? "",
            "html": (try? el.html()) ?? "",
            "outer": (try? el.outerHtml()) ?? "",
            "ownText": (try? el.ownText()) ?? "",
            "data": (try? el.data()) ?? "",
        ] as [String: Any]
    }

    func nJsoupDoc(_ html: String, base: String) -> Any? {
        do {
            let doc = try SwiftSoup.parse(html, base)
            var d = Self.elDict(doc)
            d["title"] = (try? doc.title()) ?? ""
            return d
        } catch { jsThrow("jsoup parse: \(error)"); return nil }
    }

    func nJsoupSelect(_ html: String, css: String, base: String) -> Any? {
        do {
            let doc = try SwiftSoup.parse(html, base)
            return try doc.select(css).array().map(Self.elDict)
        } catch { jsThrow("jsoup select '\(css)': \(error)"); return nil }
    }

    func nJsoupChildren(_ html: String) -> Any? {
        do {
            let doc = try SwiftSoup.parse(html)
            let root = doc.body() ?? doc
            return root.children().array().map(Self.elDict)
        } catch { jsThrow("jsoup children: \(error)"); return nil }
    }

    func nJsoupRemove(_ html: String, css: String, base: String) -> Any? {
        do {
            let doc = try SwiftSoup.parse(html, base)
            try doc.select(css).remove()
            let root = doc.body() ?? doc
            return Self.elDict(root)
        } catch { jsThrow("jsoup remove: \(error)"); return nil }
    }

    // MARK: - 文件

    func nFileInfo(_ path: String) -> [String: Any] {
        let p = Self.resolvePath(path)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: p, isDirectory: &isDir)
        let attrs = try? fm.attributesOfItem(atPath: p)
        return [
            "exists": exists,
            "isDirectory": isDir.boolValue,
            "length": (attrs?[.size] as? Int) ?? 0,
            "name": (p as NSString).lastPathComponent,
            "path": p,
            "lastModified": ((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000,
        ] as [String: Any]
    }

    func nFileList(_ path: String) -> [String] {
        let p = Self.resolvePath(path)
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: p) else { return [] }
        return items.map { (p as NSString).appendingPathComponent($0) }.sorted()
    }

    func nDownloadFile(_ a: [Any]) -> Any? {
        guard let urlStr = str(a, 0), let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(Self.defaultUA, forHTTPHeaderField: "User-Agent")
        guard let resp = HTTPClient.shared.requestSync(req) else { return nil }
        let name: String
        if let given = str(a, 1), !given.isEmpty { name = given }
        else { name = url.lastPathComponent.isEmpty ? Self.digestHex("MD5", Data(urlStr.utf8)) : url.lastPathComponent }
        let p = Self.resolvePath(name)
        do {
            try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try resp.data.write(to: URL(fileURLWithPath: p))
            return p
        } catch { jsThrow("downloadFile: \(error)"); return nil }
    }

    func nGetTxtInFolder(_ path: String) -> Any? {
        let p = Self.resolvePath(path)
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: p) else { return nil }
        var out = ""
        for name in items.sorted() where name.lowercased().hasSuffix(".txt") {
            let fp = (p as NSString).appendingPathComponent(name)
            if let d = fm.contents(atPath: fp) {
                out += HTTPClient.decode(d, charset: nil, contentType: nil) + "\n"
            }
        }
        return out
    }

    func nPutFile(_ a: [Any]) -> Any? {
        let key = str(a, 0) ?? ""
        let content = str(a, 1) ?? ""
        let p = Self.cacheFilePath(key)
        do {
            try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try Data(content.utf8).write(to: URL(fileURLWithPath: p))
            Self.cachePut(key, data: Data(p.utf8), deadline: num(a, 2) ?? 0)
            return p
        } catch { jsThrow("putFile: \(error)"); return nil }
    }

    // MARK: - 编码 helpers

    static func signedArray(_ d: Data) -> [Int] {
        d.map { Int(Int8(bitPattern: $0)) }
    }

    static func dataArg(_ v: Any?) -> Data {
        if let d = v as? Data { return d }
        if let s = v as? String { return Data(s.utf8) }
        if let arr = v as? [Any] {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(arr.count)
            for x in arr {
                if let n = x as? NSNumber { bytes.append(UInt8(truncatingIfNeeded: n.intValue)) }
            }
            return Data(bytes)
        }
        return Data()
    }

    static func decodeBase64(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        t = t.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    static func formEncode(_ s: String, charset: String?) -> String {
        let enc = HTTPClient.encoding(named: charset) ?? .utf8
        let data = s.data(using: enc) ?? Data(s.utf8)
        var out = ""
        for b in data {
            let c = Character(UnicodeScalar(b))
            if c.isLetter && b < 128 || c.isNumber && b < 128 || "-_.*".contains(c) { out.append(c) }
            else if c == " " { out += "+" }
            else { out += String(format: "%%%02X", b) }
        }
        return out
    }

    static func timeFormat(_ pattern: String, utc: Bool) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        if utc { df.timeZone = TimeZone(identifier: "UTC") }
        df.dateFormat = pattern
        return df.string(from: Date())
    }

    static func androidId() -> String {
        let key = "LegadoEngine.androidId"
        if let v = UserDefaults.standard.string(forKey: key) { return v }
        var bytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, 8, &bytes)
        let v = bytes.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(v, forKey: key)
        return v
    }

    static func resolvePath(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        return (filesRoot as NSString).appendingPathComponent(path)
    }

    static var engineRoot: String {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let p = caches.appendingPathComponent("LegadoEngine").path
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }
    static var filesRoot: String {
        let p = (engineRoot as NSString).appendingPathComponent("files")
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }
    static func cacheFilePath(_ key: String) -> String {
        let name = digestHex("MD5", Data(key.utf8)) + ".txt"
        return (filesRoot as NSString).appendingPathComponent(name)
    }

    // MARK: - 缓存存储（内存 + 磁盘，带过期）

    private static let storeLock = NSLock()
    private static var memCache: [String: (data: Data, deadline: Date?)] = [:]
    private static var memKV: [String: String] = [:]

    static func cachePut(_ key: String, data: Data, deadline: Double) {
        let dl: Date? = deadline > 0 ? Date(timeIntervalSinceNow: deadline / 1000.0) : nil
        storeLock.lock(); memCache[key] = (data, dl); storeLock.unlock()
        let dir = (engineRoot as NSString).appendingPathComponent("cache")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let obj: [String: Any] = ["v": data.base64EncodedString(), "d": dl?.timeIntervalSince1970 ?? 0]
        if let d = try? JSONSerialization.data(withJSONObject: obj) {
            try? d.write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent(digestHex("MD5", Data(key.utf8)) + ".json")))
        }
    }

    static func cacheGet(_ key: String, onlyDisk: Bool) -> Data? {
        if !onlyDisk {
            storeLock.lock(); let e = memCache[key]; storeLock.unlock()
            if let e {
                if let dl = e.deadline, dl < Date() { cacheDelete(key); return nil }
                return e.data
            }
        }
        let p = (engineRoot as NSString).appendingPathComponent("cache/" + digestHex("MD5", Data(key.utf8)) + ".json")
        guard let d = FileManager.default.contents(atPath: p),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let b64 = obj["v"] as? String, let data = Data(base64Encoded: b64) else { return nil }
        let dl = obj["d"] as? Double ?? 0
        if dl > 0 && dl < Date().timeIntervalSince1970 { cacheDelete(key); return nil }
        storeLock.lock()
        memCache[key] = (data, dl > 0 ? Date(timeIntervalSince1970: dl) : nil)
        storeLock.unlock()
        return data
    }

    static func cacheDelete(_ key: String) {
        storeLock.lock(); memCache.removeValue(forKey: key); storeLock.unlock()
        let p = (engineRoot as NSString).appendingPathComponent("cache/" + digestHex("MD5", Data(key.utf8)) + ".json")
        try? FileManager.default.removeItem(atPath: p)
    }

    static func memPut(_ k: String, _ v: String) { storeLock.lock(); memKV[k] = v; storeLock.unlock() }
    static func memGet(_ k: String) -> String? { storeLock.lock(); defer { storeLock.unlock() }; return memKV[k] }
    static func memDel(_ k: String) { storeLock.lock(); memKV.removeValue(forKey: k); storeLock.unlock() }

    static var infoMap: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "LegadoEngine.infoMap") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "LegadoEngine.infoMap") }
    }

    // MARK: - 摘要 / HMAC / CRC32

    static func digest(_ alg: String, _ data: Data) -> Data? {
        let name = alg.uppercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "WITH", with: "")
        switch name {
        case "MD5": return Data(Insecure.MD5.hash(data: data))
        case "SHA1": return Data(Insecure.SHA1.hash(data: data))
        case "SHA224":
            var out = [UInt8](repeating: 0, count: Int(CC_SHA224_DIGEST_LENGTH))
            data.withUnsafeBytes { _ = CC_SHA224($0.baseAddress, CC_LONG(data.count), &out) }
            return Data(out)
        case "SHA256": return Data(SHA256.hash(data: data))
        case "SHA384": return Data(SHA384.hash(data: data))
        case "SHA512": return Data(SHA512.hash(data: data))
        default: return nil
        }
    }

    static func digestHex(_ alg: String, _ data: Data) -> String {
        digest(alg, data)?.map { String(format: "%02x", $0) }.joined() ?? ""
    }

    static func hmac(_ alg: String, key: Data, msg: Data) -> Data? {
        let name = alg.uppercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "HMAC", with: "")
        let k = SymmetricKey(data: key)
        switch name {
        case "MD5": return Data(HMAC<Insecure.MD5>.authenticationCode(for: msg, using: k))
        case "SHA1": return Data(HMAC<Insecure.SHA1>.authenticationCode(for: msg, using: k))
        case "SHA224":
            var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            key.withUnsafeBytes { kk in msg.withUnsafeBytes { mm in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA224), kk.baseAddress, key.count, mm.baseAddress, msg.count, &out)
            } }
            return Data(out.prefix(Int(CC_SHA224_DIGEST_LENGTH)))
        case "SHA256": return Data(HMAC<SHA256>.authenticationCode(for: msg, using: k))
        case "SHA384": return Data(HMAC<SHA384>.authenticationCode(for: msg, using: k))
        case "SHA512": return Data(HMAC<SHA512>.authenticationCode(for: msg, using: k))
        default: return nil
        }
    }

    static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
            return c
        }
    }()

    static func crc32(_ data: Data, seed: UInt32) -> UInt32 {
        var c = seed ^ 0xFFFFFFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    // MARK: - gzip / deflate（Compression framework，ZLIB = raw deflate）

    static func streamProcess(_ input: Data, encode: Bool) -> Data {
        // ⭐⭐⭐⭐⭐⭐ **2026-11-19 CI build296 实证（Apple 平台）**：
        //   `COMPRESSION_ENCODE` / `COMPRESSION_DECODE` / `COMPRESSION_STATUS_OK` / `COMPRESSION_STATUS_END`
        //   / `COMPRESSION_STATUS_ERROR` / `COMPRESSION_STREAM_FINALIZE` / `COMPRESSION_ZLIB`
        //   ⇒ **全部不在作用域** ⇒ 之前写的 `COMPRESSION_STREAM_ENCODE`（也不存在）⇒ 两次都错 ⭐⭐⭐
        // ⇒⇒⇒ **不再猜常量名** ⇒ 全部走 **RawRepresentable 通道**（`rawValue:`）⇒ SDK 怎么导都能编过 ⭐⭐⭐
        //   · `compression_stream_operation(rawValue:)`  0=ENCODE 1=DECODE
        //   · `compression_algorithm(rawValue:)`         0=ZLIB
        //   · `compression_status(rawValue:)`            0=OK 1=END -1=ERROR
        //   · `compression_stream_flags(rawValue:)`      1=FINALIZE
        var stream = compression_stream()
        // ⚠️⚠️⚠️ **CI 自省（读 SDK compression.h）拿到的真实值**（2026-11-19）：
        //   COMPRESSION_STREAM_ENCODE = 0 / COMPRESSION_STREAM_DECODE = 1
        //   COMPRESSION_ZLIB           = **0x205**（不是 0！！）⭐⭐⭐
        //   COMPRESSION_STATUS_OK = 0 / END = 1 / ERROR = -1
        //   COMPRESSION_STREAM_FINALIZE = 0x0001
        // ⚠️ **rawValue 是 UInt32** ⇒ `Int32(...)` 编不过 ⇒ **ERROR 的 -1 也编不过**（UInt32 没有负数）
        //   ⇒ ⇒ 不构造 ERROR，改用「不是 OK 也不是 END ⇒ 失败」⭐⭐⭐
        // ⭐⭐⭐⭐⭐ **CI 自省（读 SDK compression.h）拿到的权威值**：
        //   COMPRESSION_STREAM_ENCODE = 0 / COMPRESSION_STREAM_DECODE = 1
        //   COMPRESSION_ZLIB           = **0x205**（不是 0！！）⭐⭐⭐
        //   COMPRESSION_STATUS_OK = 0 / END = 1 / ERROR = -1
        //   COMPRESSION_STREAM_FINALIZE = 0x0001
        // ⚠️ 这些枚举在 Apple 上是 **uint32_t 基础类型** ⇒ **直接传 UInt32 数值**，
        //   不包 `compression_*` 类型（包了类型不对 ⇒ 编译器会挑别的重载 ⇒ 报
        //   「missing arguments for parameters dst_ptr...」这个**极具误导性**的错）⭐⭐⭐
        let ccOp = UInt32(encode ? 0 : 1)      // COMPRESSION_STREAM_ENCODE / _DECODE
        let ccAlg = UInt32(0x205)              // COMPRESSION_ZLIB
        let ccStatusOK = UInt32(0)             // COMPRESSION_STATUS_OK
        let ccStatusEND = UInt32(1)            // COMPRESSION_STATUS_END
        // ⭐ `compression_stream_process` 的 flags 参数是 Int32 ⇒ 用 bitPattern 转
        let finalizeFlag = Int32(bitPattern: UInt32(0x0001))   // COMPRESSION_STREAM_FINALIZE
        guard compression_stream_init(&stream, ccOp, ccAlg) == ccStatusOK else { return Data() }
        defer { compression_stream_destroy(&stream) }
        let bufSize = 65536
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { dst.deallocate() }
        var output = Data()
        var emptyByte: UInt8 = 0
        let status: UInt32 = input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> UInt32 in
            if let base = src.baseAddress {
                stream.src_ptr = base.assumingMemoryBound(to: UInt8.self)
            } else {
                withUnsafeMutablePointer(to: &emptyByte) { stream.src_ptr = UnsafePointer($0) }
            }
            stream.src_size = src.count
            var st = ccStatusOK
            repeat {
                stream.dst_ptr = dst
                stream.dst_size = bufSize
                st = compression_stream_process(&stream, finalizeFlag)
                if st == ccStatusOK || st == ccStatusEND {
                    output.append(dst, count: bufSize - stream.dst_size)
                }
            } while st == ccStatusOK && (stream.src_size > 0 || stream.dst_size == 0)
            return st
        }
        // ⚠️ 不比较 ERROR（ERROR = -1 ⇒ UInt32 装不下）⇒ 「既不是 OK 也不是 END ⇒ 失败」
        return (status == ccStatusOK || status == ccStatusEND) ? output : Data()
    }

    static func deflate(_ data: Data, compress: Bool, nowrap: Bool) -> Data {
        let raw = streamProcess(data, encode: compress)
        if nowrap { return raw }
        if compress {
            // zlib 头 + adler32
            var out = Data([0x78, 0x9C])
            out.append(raw)
            var a: UInt32 = 1, b: UInt32 = 0
            for byte in data { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
            let adler = (b << 16) | a
            out.append(contentsOf: [UInt8(adler >> 24 & 0xFF), UInt8(adler >> 16 & 0xFF), UInt8(adler >> 8 & 0xFF), UInt8(adler & 0xFF)])
            return out
        } else {
            guard data.count > 6 else { return Data() }
            return streamProcess(data.subdata(in: 2..<(data.count - 4)), encode: false)
        }
    }

    static func gzip(_ data: Data, compress: Bool) -> Data {
        if compress {
            var out = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF])
            out.append(streamProcess(data, encode: true))
            let crc = crc32(data, seed: 0)
            let size = UInt32(truncatingIfNeeded: data.count)
            for v in [crc, size] {
                out.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)])
            }
            return out
        } else {
            // 跳过 gzip 头（支持 FEXTRA/FNAME/FCOMMENT/FHCRC）
            guard data.count > 18, data[0] == 0x1F, data[1] == 0x8B else { return Data() }
            let flg = data[3]
            var pos = 10
            if flg & 0x04 != 0 { // FEXTRA
                guard pos + 2 <= data.count else { return Data() }
                let xlen = Int(data[pos]) | Int(data[pos + 1]) << 8
                pos += 2 + xlen
            }
            if flg & 0x08 != 0 { while pos < data.count && data[pos] != 0 { pos += 1 }; pos += 1 } // FNAME
            if flg & 0x10 != 0 { while pos < data.count && data[pos] != 0 { pos += 1 }; pos += 1 } // FCOMMENT
            if flg & 0x02 != 0 { pos += 2 } // FHCRC
            guard pos < data.count - 8 else { return Data() }
            return streamProcess(data.subdata(in: pos..<(data.count - 8)), encode: false)
        }
    }

    // MARK: - 对称加密（CommonCrypto + GCM via CryptoKit）

    func nCrypto(_ a: [Any]) -> Any? { nCipher(a) }

    func nCipher(_ a: [Any]) -> Any? {
        // (enc, transformation, key, iv, data, tag?, aad?)
        let isEnc: Bool
        if let s = str(a, 0) { isEnc = s == "enc" || s == "encrypt" || s == "true" }
        else { isEnc = bool(a, 0) }
        let t = str(a, 1) ?? "AES"
        let parts = t.uppercased().split(separator: "/").map(String.init)
        let algName = parts[0]
        let mode = parts.count > 1 ? parts[1] : "ECB"
        let padding = parts.count > 2 ? parts[2] : "PKCS5PADDING"
        let noPadding = padding.contains("NOPADDING")
        let keyData = Self.dataArg(a.count > 2 ? a[2] : nil)
        let ivData = Self.dataArg(a.count > 3 ? a[3] : nil)
        let inputData: Data
        if isEnc {
            inputData = Self.dataArg(a.count > 4 ? a[4] : nil)
        } else {
            let v = a.count > 4 ? a[4] : nil
            if let s = v as? String {
                inputData = Self.decodeBase64(s) ?? Data(hex: s) ?? Data(s.utf8)
            } else {
                inputData = Self.dataArg(v)
            }
        }
        let outMode = str(a, 5) ?? "bytes"

        // GCM（CryptoKit）
        if mode == "GCM" {
            guard algName == "AES" else { jsThrow("GCM 仅支持 AES"); return nil }
            do {
                let key = SymmetricKey(data: keyData)
                let nonce = try AES.GCM.Nonce(data: ivData.isEmpty ? Data(count: 12) : ivData)
                if isEnc {
                    let aad = Self.dataArg(a.count > 6 ? a[6] : nil)
                    let sealed = try AES.GCM.seal(inputData, using: key, nonce: nonce, authenticating: aad)
                    var out = sealed.ciphertext
                    out.append(sealed.tag)
                    return Self.cipherOut(out, mode: outMode)
                } else {
                    let tagData = Self.dataArg(a.count > 5 && !(a[5] is NSNull) && str(a, 5) == nil ? a[5] : nil)
                    let ct: Data, tag: Data
                    if !tagData.isEmpty { ct = inputData; tag = tagData }
                    else {
                        guard inputData.count >= 16 else { jsThrow("GCM 数据过短"); return nil }
                        ct = inputData.prefix(inputData.count - 16)
                        tag = inputData.suffix(16)
                    }
                    let aad = Self.dataArg(a.count > 6 ? a[6] : nil)
                    let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
                    let opened = try AES.GCM.open(box, using: key, authenticating: aad)
                    return Self.cipherOut(opened, mode: outMode)
                }
            } catch { jsThrow("GCM: \(error)"); return nil }
        }

        let alg: CCAlgorithm
        let blockSize: Int
        switch algName {
        case "AES": alg = CCAlgorithm(kCCAlgorithmAES); blockSize = kCCBlockSizeAES128
        case "DES": alg = CCAlgorithm(kCCAlgorithmDES); blockSize = kCCBlockSizeDES
        case "DESEDE", "3DES", "TRIPLEDES": alg = CCAlgorithm(kCCAlgorithm3DES); blockSize = kCCBlockSize3DES
        case "BLOWFISH": alg = CCAlgorithm(kCCAlgorithmBlowfish); blockSize = kCCBlockSizeBlowfish
        default: jsThrow("不支持的算法 \(algName)"); return nil
        }
        let ccMode: CCMode
        switch mode {
        case "ECB": ccMode = CCMode(kCCModeECB)
        case "CBC": ccMode = CCMode(kCCModeCBC)
        case "CFB": ccMode = CCMode(kCCModeCFB)
        case "CTR": ccMode = CCMode(kCCModeCTR)
        case "OFB": ccMode = CCMode(kCCModeOFB)
        default: jsThrow("不支持的模式 \(mode)"); return nil
        }
        let usePadding = !noPadding && (mode == "ECB" || mode == "CBC")
        var iv = ivData
        if iv.isEmpty && mode != "ECB" { iv = Data(count: blockSize) }
        let op: CCOperation = isEnc ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt)
        let outCap = inputData.count + blockSize * 2 + 16
        var out = Data(count: outCap)
        var moved = 0
        // create → update → final
        var cryptor: CCCryptorRef?
        // ⭐⭐⭐ **CCCryptorCreateWithMode 的 Darwin 签名是 11 个参数**（2026-11-19 CI build296 实证）：
        //   (op, mode, alg, padding, iv, key, keyLength, **data, dataLength, options**, cryptorRef)
        //   ⇒ 原代码多传了一个 `0` ⇒ 编译不过 ⭐⭐⭐
        // ⚠️ `kCCModeOptionCTR_BE` **只在 CTR 模式**能传（ECB/CBC 传了 ⇒ kCCParamError）⭐⭐⭐
        let ccOptions: CCModeOptions = (mode == "CTR") ? CCModeOptions(kCCModeOptionCTR_BE) : CCModeOptions(0)
        // ⭐⭐⭐⭐⭐⭐ **CI 自省 + swiftc 探针（build296）：Apple 上 `kCCPaddingPKCS7` /
        //   `kCCPaddingNoPadding` / `kCCPKCS7Padding` / `ccNoPadding` **全部不在作用域** ⭐⭐⭐
        //   ⇒ **不猜名字了** ⇒ 直接用 `CCPadding` 的 raw 值：
        //     0 = 无填充 / 1 = PKCS7（CommonCrypto 的 CCPadding 枚举值）⭐⭐⭐
        // ⭐⭐⭐ **不写类型标注** ⇒ 让 Swift 隐式转成参数类型（CCPadding 是 uint32_t 基础类型）
        //   ⇒ 之前写 `CCPadding(1)` 报「generic parameter 'ContentType' could not be inferred」
        //      ⇒ 说明 `CCPadding` 被导入成了**泛型别名** ⇒ 压根别碰它，直接给字面量 ⭐⭐⭐
        let ccPadding = usePadding ? 1 : 0      // 1 = PKCS7 / 0 = 无填充
        let createStatus = iv.withUnsafeBytes { ivPtr in
            keyData.withUnsafeBytes { keyPtr in
                // ⚠️ ECB 模式**必须传 NULL IV**（传了 ⇒ kCCParamError ⇒ 旧代码 ECB/CBC 拿不到结果）
                // ⭐⭐⭐ **CI 实证：`withUnsafeBytes` 的 `ivPtr` 是 `UnsafeRawBufferPointer`**
                //   ⇒ 它**不能**直接当 `UnsafeRawPointer?` 用 ⇒ 要经 `baseAddress` 转一下 ⭐⭐⭐
                // ⭐⭐⭐ **CI 实证：`ivPtr.baseAddress` 的类型是 `UnsafeRawPointer<Element>?`（泛型）**
                //   ⇒ 直接赋给 `UnsafeRawPointer?` 编不过 ⇒ **要显式转成非泛型的 UnsafeRawPointer** ⭐⭐⭐
                let ivArg: UnsafeRawPointer? = (mode == "ECB")
                    ? nil
                    : ivPtr.baseAddress.map { UnsafeRawPointer($0) }
                CCCryptorCreateWithMode(op, ccMode, alg, ccPadding,
                    ivArg, keyPtr.baseAddress, keyData.count,
                    nil, 0, ccOptions, &cryptor)
            }
        }
        guard createStatus == kCCSuccess, let cr = cryptor else {
            jsThrow("CCCryptorCreate 失败 (\(createStatus))"); return nil
        }
        defer { CCCryptorRelease(cr) }
        var result = Data()
        let updateStatus = inputData.withUnsafeBytes { inPtr in
            out.withUnsafeMutableBytes { outPtr in
                CCCryptorUpdate(cr, inPtr.baseAddress, inputData.count, outPtr.baseAddress, outCap, &moved)
            }
        }
        guard updateStatus == kCCSuccess else { jsThrow("CCCryptorUpdate 失败 (\(updateStatus))"); return nil }
        result.append(out.prefix(moved))
        let finalStatus = out.withUnsafeMutableBytes { outPtr in
            CCCryptorFinal(cr, outPtr.baseAddress, outCap, &moved)
        }
        guard finalStatus == kCCSuccess else { jsThrow("CCCryptorFinal 失败 (\(finalStatus))"); return nil }
        result.append(out.prefix(moved))
        return Self.cipherOut(result, mode: outMode)
    }

    static func cipherOut(_ d: Data, mode: String) -> Any? {
        switch mode {
        case "base64", "rawstr": return d.base64EncodedString()
        case "hex": return d.map { String(format: "%02x", $0) }.joined()
        case "str": return String(data: d, encoding: .utf8) ?? ""
        default: return signedArray(d)
        }
    }

    // MARK: - RSA（Security framework）

    static func rsaKey(_ keyArg: Any?, isPub: Bool) -> SecKey? {
        let der: Data
        if let s = keyArg as? String { der = decodeBase64(s) ?? Data() }
        else { der = dataArg(keyArg) }
        guard !der.isEmpty else { return nil }
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: isPub ? kSecAttrKeyClassPublic : kSecAttrKeyClassPrivate,
        ]
        var err: Unmanaged<CFError>?
        let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &err)
        return key
    }

    static func rsaPadding(_ t: String) -> SecKeyAlgorithm? {
        let u = t.uppercased()
        if u.contains("OAEP") {
            if u.contains("SHA256") || u.contains("SHA-256") { return .rsaEncryptionOAEPSHA256 }
            if u.contains("SHA512") || u.contains("SHA-512") { return .rsaEncryptionOAEPSHA512 }
            // ⚠️ SDK 里**没有** `.rsaEncryptionOAEP`（只有 OAEPSHA1/SHA256/SHA384/SHA512）
            //   ⇒ 2026-11-19 CI build296 实证：报 `cannot be resolved without a contextual type` ⭐⭐⭐
            //   ⇒ 传统 OAEP = SHA-1 ⇒ 用 `.rsaEncryptionOAEPSHA1` ⭐⭐⭐
            return .rsaEncryptionOAEPSHA1
        }
        if u.contains("NOPADDING") { return .rsaEncryptionRaw }
        return .rsaEncryptionPKCS1
    }

    func nRSA(_ a: [Any]) -> Any? {
        // (enc, transformation, key, isPub, data, out)
        let isEnc: Bool
        if let s = str(a, 0) { isEnc = s == "enc" || s == "true" } else { isEnc = bool(a, 0) }
        let t = str(a, 1) ?? "RSA"
        let isPub = bool(a, 3)
        guard let key = Self.rsaKey(a.count > 2 ? a[2] : nil, isPub: isPub) else { jsThrow("RSA 密钥无效"); return nil }
        guard let pad = Self.rsaPadding(t) else { jsThrow("RSA padding 不支持: \(t)"); return nil }
        let input: Data
        let v = a.count > 4 ? a[4] : nil
        if !isEnc, let s = v as? String { input = Self.decodeBase64(s) ?? Data(hex: s) ?? Data(s.utf8) }
        else { input = Self.dataArg(v) }
        var err: Unmanaged<CFError>?
        let out: CFData?
        if isEnc { out = SecKeyCreateEncryptedData(key, pad, input as CFData, &err) }
        else { out = SecKeyCreateDecryptedData(key, pad, input as CFData, &err) }
        guard let result = out else {
            jsThrow("RSA: \(err.map { $0.takeRetainedValue().localizedDescription } ?? "失败")")
            return nil
        }
        return Self.cipherOut(result as Data, mode: str(a, 5) ?? "bytes")
    }

    func nRSAGen() -> Any? {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var err: Unmanaged<CFError>?
        guard let pri = SecKeyCreateRandomKey(attrs as CFDictionary, &err),
              let pub = SecKeyCopyPublicKey(pri),
              let priData = SecKeyCopyExternalRepresentation(pri, &err),
              let pubData = SecKeyCopyExternalRepresentation(pub, &err) else {
            jsThrow("rsaGen 失败"); return nil
        }
        return ["pub": (pubData as Data).base64EncodedString(),
                "pri": (priData as Data).base64EncodedString()]
    }

    static func signAlg(_ alg: String) -> SecKeyAlgorithm? {
        let u = alg.uppercased().replacingOccurrences(of: "WITH", with: "").replacingOccurrences(of: "-", with: "")
        switch u {
        case "SHA1RSA", "SHA1": return .rsaSignatureMessagePKCS1v15SHA1
        case "SHA224RSA": return .rsaSignatureMessagePKCS1v15SHA224
        case "SHA256RSA", "SHA256": return .rsaSignatureMessagePKCS1v15SHA256
        case "SHA384RSA": return .rsaSignatureMessagePKCS1v15SHA384
        case "SHA512RSA", "SHA512": return .rsaSignatureMessagePKCS1v15SHA512
        default: return nil
        }
    }

    func nRSASign(_ a: [Any]) -> Any? {
        guard let alg = Self.signAlg(str(a, 0) ?? "SHA256withRSA") else { jsThrow("签名算法不支持: \(str(a, 0) ?? "")"); return nil }
        guard let key = Self.rsaKey(a.count > 1 ? a[1] : nil, isPub: false) else { jsThrow("RSA 私钥无效"); return nil }
        let data = Self.dataArg(a.count > 2 ? a[2] : nil)
        var err: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(key, alg, data as CFData, &err) else {
            jsThrow("rsaSign: \(err.map { $0.takeRetainedValue().localizedDescription } ?? "失败")")
            return nil
        }
        return Self.cipherOut(sig as Data, mode: str(a, 3) ?? "bytes")
    }

    func nRSAVerify(_ a: [Any]) -> Any? {
        guard let alg = Self.signAlg(str(a, 0) ?? "SHA256withRSA") else { return false }
        guard let key = Self.rsaKey(a.count > 1 ? a[1] : nil, isPub: true) else { return false }
        let data = Self.dataArg(a.count > 2 ? a[2] : nil)
        let sigV = a.count > 3 ? a[3] : nil
        let sig: Data
        if let s = sigV as? String { sig = Self.decodeBase64(s) ?? Data(hex: s) ?? Data() }
        else { sig = Self.dataArg(sigV) }
        var err: Unmanaged<CFError>?
        return SecKeyVerifySignature(key, alg, data as CFData, sig as CFData, &err)
    }
}

// MARK: - hex Data

extension Data {
    init?(hex: String) {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = chars[i].hexDigitValue, let lo = chars[i + 1].hexDigitValue else { return nil }
            bytes.append(UInt8(hi << 4 | lo))
            i += 2
        }
        self.init(bytes)
    }
}

#endif