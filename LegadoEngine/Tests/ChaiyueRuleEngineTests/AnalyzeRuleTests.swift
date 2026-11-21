import Foundation
import ChaiyueModels
import Testing
@testable import ChaiyueEngine

@Suite("规则解析")
struct AnalyzeRuleTests {
    let session: RuleSession

    init() throws {
        session = makeSession(try makeSource(minimalSourceJSON), env: makeEnvironment())
    }

    private func rule(_ content: Any, baseUrl: String = "https://example.com/list") throws -> AnalyzeRule {
        let r = AnalyzeRule(session: session, ruleData: RuleData())
        _ = try r.setContent(content, baseUrl: baseUrl)
        _ = r.setRedirectUrl(baseUrl)
        return r
    }

    static let html = """
    <html><body>
    <div class="item"><a href="/book/1">书一</a><span class="author">作者：甲</span></div>
    <div class="item"><a href="/book/2">书二</a><span class="author">作者：乙</span></div>
    <p id="intro">简介&amp;说明</p>
    </body></html>
    """

    @Test func jsoupDefaultRules() throws {
        let r = try rule(Self.html)
        let items = try r.getElements("class.item")
        #expect(items.count == 2)
        #expect(try r.getString("class.item.0@tag.a@text") == "书一")
        #expect(try r.getString("class.item.-1@tag.a@href", isUrl: true) == "https://example.com/book/2")
        #expect(try r.getStringList("class.item@tag.a@text") == ["书一", "书二"])
        #expect(try r.getString("id.intro@text") == "简介&说明")
        #expect(try r.getString("@css:.item:nth-child(2) .author@text") == "作者：乙")
    }

    @Test func replaceAndCombine() throws {
        let r = try rule(Self.html)
        #expect(try r.getString("class.author.0@text##作者：") == "甲")
        #expect(try r.getString("class.author.0@text##作者：(.)##$1君###") == "甲君")
        #expect(try r.getString("class.nothing@text||class.item.1@tag.a@text") == "书二")
        #expect(try r.getStringList("class.item.0@tag.a@text&&class.item.1@tag.a@text") == ["书一", "书二"])
    }

    @Test func jsonPathRules() throws {
        let json = #"{"data":{"list":[{"name":"甲","id":1},{"name":"乙","id":2}],"total":2}}"#
        let r = try rule(json)
        #expect(try r.getString("$.data.total") == "2")
        #expect(try r.getStringList("$.data.list[*].name") == ["甲", "乙"])
        #expect(try r.getElements("$.data.list").count == 2)
        #expect(try r.getString("data.list[0].name") == "甲")
        // 与 Legado 一致：模板内嵌规则作用于当前 content，列表解析时逐项 setContent
        let items = try r.getElements("$.data.list[*]")
        _ = try r.setContent(items[1])
        #expect(try r.getString("{{$.name}}-{{$.id}}") == "乙-2")
    }

    @Test func xpathRules() throws {
        let r = try rule(Self.html)
        #expect(try r.getString("//div[@class='item'][1]/a/text()") == "书一")
        #expect(try r.getStringList("//div[@class='item']/a/@href") == ["/book/1", "/book/2"])
    }

    @Test func regexAllInOne() throws {
        let r = try rule(Self.html)
        let items = try r.getElements(":<a href=\"([^\"]+)\">([^<]+)</a>")
        #expect(items.count == 2)
        #expect(try r.getString("$2", content: items[0]) == "书一")
    }

    @Test func jsAndTemplates() throws {
        let r = try rule(Self.html)
        #expect(try r.getString("class.item.0@tag.a@text<js>result + '!'</js>") == "书一!")
        #expect(try r.getString("@js:1+2") == "3")
        #expect(try r.getString("{{1+1}}本") == "2本")
        #expect(try r.getString("@js:java.md5Encode('abc')") == "900150983cd24fb0d6963f7d28e17f72")
    }

    @Test func putAndGet() throws {
        let r = try rule(Self.html)
        _ = try r.getString("@put:{bid:class.item.1@tag.a@href}class.item.0@tag.a@text")
        #expect(r.get("bid") == "/book/2")
        #expect(try r.getString("@get:{bid}") == "/book/2")
        #expect(try r.getString("@js:java.get('bid')") == "/book/2")
    }
}

@Suite("JS 运行时")
struct JSRuntimeTests {
    let session: RuleSession

    init() throws {
        session = makeSession(try makeSource(minimalSourceJSON), env: makeEnvironment())
    }

    private func eval(_ js: String) throws -> String {
        AnalyzeUrl.stringify(try session.evalSourceJS(js))
    }

    @Test func letRedeclarationAcrossEvals() throws {
        #expect(try eval("let a = 1; a + 1") == "2")
        #expect(try eval("let a = 5; a") == "5")
        #expect(try eval("({a: 1}).a") == "1")
    }

    @Test func javaStringShim() throws {
        #expect(try eval("var S = Packages.java.lang.String; new S('你好').getBytes('UTF-8').length") == "6")
        #expect(try eval("var S = Packages.java.lang.String; typeof S('x')") == "string")
        #expect(try eval("var S = Packages.java.lang.String; new S([-28,-67,-96,-27,-91,-67], 'UTF-8').toString()") == "你好")
    }

    @Test func javaImporterWith() throws {
        let js = """
        var imp = new JavaImporter();
        imp.importClass(Packages.java.lang.String);
        imp.importClass(Packages.java.net.URL);
        with (imp) { var h = URL('https://a.b.com:8080/x?y=1').host; var s = String(''); }
        h + '|' + (s || 'empty')
        """
        #expect(try eval(js) == "a.b.com|empty")
    }

    @Test func aesGcmViaPackages() throws {
        let js = """
        var Cipher = Packages.javax.crypto.Cipher;
        var Spec = Packages.javax.crypto.spec;
        var key = new Packages.java.lang.String('0123456789abcdef0123456789abcdef').getBytes('UTF-8');
        var iv = new Packages.java.lang.String('abcdefghijkl').getBytes('UTF-8');
        var enc = Cipher.getInstance('AES/GCM/NoPadding');
        enc.init(Cipher.ENCRYPT_MODE, new Spec.SecretKeySpec(key, 'AES'), new Spec.GCMParameterSpec(128, iv));
        var data = enc.doFinal(new Packages.java.lang.String('秘密').getBytes('UTF-8'));
        var dec = Cipher.getInstance('AES/GCM/NoPadding');
        dec.init(Cipher.DECRYPT_MODE, new Spec.SecretKeySpec(key, 'AES'), new Spec.GCMParameterSpec(128, iv));
        new Packages.java.lang.String(dec.doFinal(data), 'UTF-8').toString()
        """
        #expect(try eval(js) == "秘密")
    }

    @Test func symmetricCryptoAndBase64() throws {
        let js = """
        var c = java.createSymmetricCrypto('AES/CBC/PKCS5Padding', '1234567890123456', 'abcdefghijklmnop');
        var b64 = c.encryptBase64('hello');
        c.decryptStr(b64) + '|' + java.base64Decode(java.base64Encode('中文'))
        """
        #expect(try eval(js) == "hello|中文")
        #expect(try eval("Packages.android.util.Base64.encodeToString(java.strToBytes('abc'), 2)") == "YWJj")
    }

    /// Hutool 5.8.22 + BouncyCastle 1.86 拒绝 17 字节 AES 密钥和 IV，不截断也不补零
    @Test func aesRejectsIllegalKeyAndIvLength() throws {
        let js = """
        function attempt(key, iv) {
          try {
            var c = java.createSymmetricCrypto('AES/CBC/PKCS5Padding', key, iv);
            c.encryptBase64('hi');
            return 'ok';
          } catch (e) { return 'fail'; }
        }
        attempt('1234567890123456', 'abcdefghijklmnop')
          + '|' + attempt('G@tY3$jK7#mL2&pW8', 'C!eH4&sM6@wP9^zX1')
          + '|' + attempt('1234567890123456', 'C!eH4&sM6@wP9^zX1')
          + '|' + attempt('12345678901234567', 'abcdefghijklmnop')
        """
        #expect(try eval(js) == "ok|fail|fail|fail")
    }

    @Test func loginInfoRoundTripIsLegadoCompatible() throws {
        session.state.loginInfo = #"{"邮箱":"a@b.c"}"#
        #expect(try eval("source.getLoginInfoMap().get('邮箱')") == "a@b.c")
        #expect(try eval("source.getLoginInfoMap()['邮箱']") == "a@b.c")
        // 书源自行加密写入的格式也能读取
        let js = """
        var c = java.createSymmetricCrypto('AES', java.androidId());
        cache.put('userInfo_' + source.getKey(), Packages.android.util.Base64.encodeToString(c.encrypt('{"k":"v"}'), 2));
        source.getLoginInfo()
        """
        #expect(try eval(js) == #"{"k":"v"}"#)
    }

    @Test func environmentLooksLikeApple() throws {
        #expect(try eval("typeof java.qread") == "undefined")
        #expect(try eval("typeof java.reLoginView") == "undefined")
        #expect(try eval("typeof java.deviceID()") == "string")
        #expect(try eval("typeof source.loginUi") != "function")
        #expect(try eval("java.androidId().length") == "16")
    }

    @Test func sourceVariablesAndCache() throws {
        _ = try eval("source.setVariable('{\"x\":1}'); source.put('k', 'v'); cache.putMemory('m', 3)")
        #expect(try eval("source.getVariable()") == #"{"x":1}"#)
        #expect(try eval("source.get('k')") == "v")
        #expect(try eval("cache.getFromMemory('m') + 1") == "4")
    }
}
