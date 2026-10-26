// ====== Packages/JavaImporter 兼容层 ======
// 模拟 Rhino/legado 的 Java 包导入机制
// 书源使用 Packages.javax.crypto.Cipher 等 Java 类进行加密解密，
// 此脚本在 JavaScriptCore 中提供等价的纯 JS 实现，底层委托给 Swift 原生函数。

// ====== String.prototype.getBytes (模拟 java.lang.String.getBytes) ======
if (typeof String.prototype.getBytes !== 'function') {
    String.prototype.getBytes = function(charset) {
        if (charset && typeof _nativeStrToBytes === 'function') {
            return _nativeStrToBytes(this.toString(), String(charset));
        }
        // 默认 UTF-8 编码
        var str = this.toString();
        var bytes = [];
        for (var i = 0; i < str.length; i++) {
            var c = str.charCodeAt(i);
            if (c < 0x80) {
                bytes.push(c);
            } else if (c < 0x800) {
                bytes.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
            } else if (c >= 0xd800 && c <= 0xdbff && i + 1 < str.length) {
                var hi = c, lo = str.charCodeAt(++i);
                var cp = ((hi - 0xd800) << 10) + (lo - 0xdc00) + 0x10000;
                bytes.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
            } else {
                bytes.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
            }
        }
        return bytes;
    };
}

// ====== JavaImporter (模拟 Rhino 的 JavaImporter + with 语句) ======
if (typeof JavaImporter === 'undefined' || !JavaImporter.__qireaderCompatibleJavaImporter) {
    JavaImporter = function() {
        var self = {};
        var _importPkg = function() {
            for (var i = 0; i < arguments.length; i++) {
                var pkg = arguments[i];
                if (pkg && typeof pkg === 'object') {
                    if (pkg.__javaClassName) {
                        self[pkg.__javaClassName] = pkg;
                        continue;
                    }
                    for (var k in pkg) {
                        if (pkg.hasOwnProperty(k)) self[k] = pkg[k];
                    }
                } else if (pkg && typeof pkg === 'function') {
                    self[pkg.__javaClassName || pkg.name] = pkg;
                }
            }
        };
        _importPkg.apply(null, arguments);
        self.importPackage = _importPkg;
        self.importClass = function() {};
        return self;
    };
    JavaImporter.__qireaderCompatibleJavaImporter = true;
}

// ====== importPackage 全局函数（Rhino 兼容） ======
if (typeof importPackage === 'undefined') {
    var importPackage = function() {};
}

// ====== Packages 命名空间 ======
if (typeof Packages === 'undefined') { var Packages = {}; }

// ------ com.jayway.jsonpath ------
Packages.com = Packages.com || {};
Packages.com.jayway = Packages.com.jayway || {};
Packages.com.jayway.jsonpath = Packages.com.jayway.jsonpath || {};
Packages.com.jayway.jsonpath.Option = Packages.com.jayway.jsonpath.Option || {
    SUPPRESS_EXCEPTIONS: 'SUPPRESS_EXCEPTIONS'
};
Packages.com.jayway.jsonpath.Configuration = Packages.com.jayway.jsonpath.Configuration || {
    builder: function() {
        var suppress = false;
        return {
            options: function() {
                for (var i = 0; i < arguments.length; i++) {
                    if (arguments[i] === Packages.com.jayway.jsonpath.Option.SUPPRESS_EXCEPTIONS) suppress = true;
                }
                return this;
            },
            build: function() { return { _suppressExceptions: suppress }; }
        };
    }
};
Packages.com.jayway.jsonpath.JsonPath = Packages.com.jayway.jsonpath.JsonPath || {
    read: function(json, path) {
        return _nativeJsonPathRead(json, String(path), false);
    },
    parse: function(json) {
        return this.using(null).parse(json);
    },
    using: function(configuration) {
        var suppress = !!(configuration && configuration._suppressExceptions);
        return {
            parse: function(json) {
                return {
                    read: function(path) {
                        return _nativeJsonPathRead(json, String(path), suppress);
                    }
                };
            }
        };
    }
};
Packages.com.jayway.jsonpath.JsonPath.__javaClassName = 'JsonPath';
Packages.com.jayway.jsonpath.Configuration.__javaClassName = 'Configuration';
Packages.com.jayway.jsonpath.Option.__javaClassName = 'Option';
if (typeof com === 'undefined') { var com = Packages.com; }

// ------ javax.crypto ------
Packages.javax = Packages.javax || {};
Packages.javax.crypto = Packages.javax.crypto || {};
Packages.javax.crypto.Cipher = Packages.javax.crypto.Cipher || {
    ENCRYPT_MODE: 1,
    DECRYPT_MODE: 2,
    getInstance: function(transformation) {
        return {
            _t: String(transformation),
            _keyBytes: null,
            _ivBytes: null,
            _opmode: 0,
            init: function(opmode, key, ivSpec) {
                this._opmode = (typeof opmode === 'number') ? opmode : 2;
                if (key) this._keyBytes = key._keyBytes || key;
                if (ivSpec) this._ivBytes = ivSpec._ivBytes || ivSpec;
            },
            doFinal: function(data) {
                var keyB64 = _nativeBase64Encode(Array.prototype.slice.call(this._keyBytes || []));
                var ivB64 = this._ivBytes ? _nativeBase64Encode(Array.prototype.slice.call(this._ivBytes)) : '';
                var dataB64 = _nativeBase64Encode(Array.prototype.slice.call(data || []));
                var isDecrypt = (this._opmode === 2);
                return _nativeCipherProcess(dataB64, keyB64, this._t, ivB64, isDecrypt);
            }
        };
    }
};
Packages.javax.crypto.SecretKeyFactory = Packages.javax.crypto.SecretKeyFactory || {
    getInstance: function(algorithm) {
        return {
            generateSecret: function(keySpec) {
                return keySpec;
            }
        };
    }
};

// ------ javax.crypto.spec ------
Packages.javax.crypto.spec = Packages.javax.crypto.spec || {};
if (!Packages.javax.crypto.spec.SecretKeySpec) {
    Packages.javax.crypto.spec.SecretKeySpec = function(keyBytes, algorithm) {
        return { _keyBytes: Array.prototype.slice.call(keyBytes), _algorithm: String(algorithm) };
    };
}
if (!Packages.javax.crypto.spec.IvParameterSpec) {
    Packages.javax.crypto.spec.IvParameterSpec = function(ivBytes) {
        return { _ivBytes: Array.prototype.slice.call(ivBytes) };
    };
}
if (!Packages.javax.crypto.spec.DESKeySpec) {
    Packages.javax.crypto.spec.DESKeySpec = function(keyBytes) {
        return { _keyBytes: Array.prototype.slice.call(keyBytes) };
    };
}

// ------ java.lang ------
Packages.java = Packages.java || {};
Packages.java.lang = Packages.java.lang || {};
var __javaStringMarkerKey = '__qireaderJavaType';
var __javaStringMarkerValue = 'java.lang.String';
function __javaIsStringLike(val) {
    return typeof val === 'string' || (val !== undefined && val !== null && (val[__javaStringMarkerKey] === __javaStringMarkerValue || Object.prototype.toString.call(val) === '[object String]'));
}
function __javaStringText(val, charset) {
    var RootString = (typeof globalThis !== 'undefined' && globalThis.String) ? globalThis.String : String;
    if (val !== undefined && val !== null && !__javaIsStringLike(val) && typeof val !== 'number' && typeof val !== 'boolean') {
        if (typeof _nativeBytesToStr === 'function') {
            return _nativeBytesToStr(Array.prototype.slice.call(val), charset || 'UTF-8');
        }
        var s = '';
        for (var i = 0; i < val.length; i++) s += RootString.fromCharCode(val[i] & 0xFF);
        return s;
    }
    return RootString(val);
}
function __javaStringObject(text) {
    var RootString = (typeof globalThis !== 'undefined' && globalThis.String) ? globalThis.String : String;
    var obj = new RootString(text);
    try {
        Object.defineProperty(obj, __javaStringMarkerKey, {
            value: __javaStringMarkerValue,
            enumerable: false,
            configurable: true
        });
    } catch (e) {
        obj[__javaStringMarkerKey] = __javaStringMarkerValue;
    }
    obj.toString = function() { return text; };
    obj.valueOf = function() { return text; };
    if (typeof obj.getBytes !== 'function') {
        obj.getBytes = function(charset) { return RootString.prototype.getBytes.call(text, charset); };
    }
    return obj;
}
if (!Packages.java.lang.String) {
    Packages.java.lang.String = function(val, charset) {
        return __javaStringObject(__javaStringText(val, charset));
    };
    Packages.java.lang.String.__javaClassName = 'String';
}
// java.lang.Integer（Rhino 兼容：书源 with(javaImport) 中使用 Integer.parseInt 等）
if (!Packages.java.lang.Integer) {
    Packages.java.lang.Integer = {
        parseInt: function(str, radix) { return parseInt(str, radix || 10); },
        valueOf: function(i) { return parseInt(i); },
        toHexString: function(i) { return (i >>> 0).toString(16); },
        toBinaryString: function(i) { return (i >>> 0).toString(2); },
        toOctalString: function(i) { return (i >>> 0).toString(8); },
        MAX_VALUE: 2147483647,
        MIN_VALUE: -2147483648
    };
}
// java.lang.Long（Rhino 兼容）
if (!Packages.java.lang.Long) {
    Packages.java.lang.Long = {
        parseLong: function(str, radix) { return parseInt(str, radix || 10); },
        valueOf: function(i) { return parseInt(i); },
        MAX_VALUE: 9007199254740991
    };
}
// java.lang.Math（委托给 JS Math）
if (!Packages.java.lang.Math) {
    Packages.java.lang.Math = Math;
}
// java.lang.System（最小存根）
if (!Packages.java.lang.System) {
    Packages.java.lang.System = {
        currentTimeMillis: function() { return Date.now(); },
        nanoTime: function() { return Date.now() * 1000000; }
    };
}
if (!Packages.java.lang.Thread) {
    Packages.java.lang.Thread = {
        sleep: function(ms) {
            ms = Math.max(0, Math.min(Number(ms) || 0, 2000));
            if (typeof _nativeSleepMillis === 'function') {
                _nativeSleepMillis(ms);
                return;
            }
            var end = Date.now() + Math.min(ms, 50);
            while (Date.now() < end) {}
        }
    };
    Packages.java.lang.Thread.__javaClassName = 'Thread';
}
if (!Packages.java.lang.StringBuilder) {
    Packages.java.lang.StringBuilder = function(initial) {
        var value = (initial === undefined || initial === null) ? '' : String(initial);
        return {
            append: function(v) { value += (v === null ? 'null' : String(v)); return this; },
            appendCodePoint: function(codePoint) { value += String.fromCodePoint ? String.fromCodePoint(codePoint) : String.fromCharCode(codePoint); return this; },
            insert: function(index, v) { index = Math.max(0, Math.min(value.length, Number(index) || 0)); value = value.slice(0, index) + (v === null ? 'null' : String(v)) + value.slice(index); return this; },
            delete: function(start, end) { start = Math.max(0, Number(start) || 0); end = Math.min(value.length, Number(end) || start); value = value.slice(0, start) + value.slice(end); return this; },
            deleteCharAt: function(index) { index = Number(index) || 0; if (index >= 0 && index < value.length) value = value.slice(0, index) + value.slice(index + 1); return this; },
            replace: function(start, end, str) { start = Math.max(0, Number(start) || 0); end = Math.min(value.length, Number(end) || start); value = value.slice(0, start) + String(str) + value.slice(end); return this; },
            substring: function(start, end) { return value.substring(start, end); },
            charAt: function(index) { return value.charAt(index); },
            length: function() { return value.length; },
            setLength: function(len) { len = Math.max(0, Number(len) || 0); value = value.length > len ? value.slice(0, len) : value + new Array(len - value.length + 1).join('\u0000'); return this; },
            toString: function() { return value; }
        };
    };
    Packages.java.lang.StringBuilder.__javaClassName = 'StringBuilder';
}
if (!Packages.java.lang.StringBuffer) {
    Packages.java.lang.StringBuffer = function(initial) {
        return new Packages.java.lang.StringBuilder(initial);
    };
    Packages.java.lang.StringBuffer.__javaClassName = 'StringBuffer';
}

// ------ java.util ------
Packages.java.util = Packages.java.util || {};
// java.util.UUID (Rhino/legado 兼容：书源常用 Packages.java.util.UUID.randomUUID())
if (!Packages.java.util.UUID) {
    Packages.java.util.UUID = {
        randomUUID: function() {
            // 优先使用原生桥接（由 Swift JsBridgeShared+Util 注册）
            if (typeof java !== 'undefined' && typeof java.randomUUID === 'function') {
                return java.randomUUID();
            }
            // 纯 JS UUID v4 回退
            return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
                var r = Math.random() * 16 | 0;
                var v = c === 'x' ? r : (r & 0x3 | 0x8);
                return v.toString(16);
            });
        },
        fromString: function(str) {
            return String(str);
        },
        nameUUIDFromBytes: function(bytes) {
            // UUID v3/v5 风格 — 生成基于名称的 UUID（MD5 版本）
            var nameStr = '';
            if (typeof bytes === 'string') {
                nameStr = bytes;
            } else if (bytes && typeof bytes.length === 'number') {
                for (var i = 0; i < bytes.length; i++) {
                    nameStr += String.fromCharCode(bytes[i] & 0xFF);
                }
            } else {
                nameStr = String(bytes || '');
            }
            var hash = '';
            if (typeof java !== 'undefined' && typeof java.md5Encode === 'function') {
                hash = java.md5Encode(nameStr);
            }
            // 格式化为 UUID
            if (hash && hash.length >= 32) {
                return (hash.substr(0, 8) + '-' + hash.substr(8, 4) + '-' +
                        '3' + hash.substr(13, 3) + '-' +
                        ((parseInt(hash.substr(16, 2), 16) & 0x3f | 0x80).toString(16)) +
                        hash.substr(18, 2) + '-' + hash.substr(20, 12));
            }
            return '00000000-0000-3000-8000-000000000000';
        }
    };
    Packages.java.util.UUID.__javaClassName = 'UUID';
}
function __javaValueToString(value) {
    if (value === null || value === undefined) return 'null';
    if (Array.isArray(value)) return '[' + value.map(__javaValueToString).join(', ') + ']';
    if (value && typeof value === 'object' && value.toString === Object.prototype.toString) {
        return '{' + Object.keys(value).map(function(key) {
            return key + '=' + __javaValueToString(value[key]);
        }).join(', ') + '}';
    }
    if (value && typeof value.toString === 'function' && value.toString !== Object.prototype.toString) return String(value.toString());
    return String(value);
}
function __javaArrayListFrom(items) {
    var arr = Array.prototype.slice.call(items || []);
    var list = {
        add: function(index, value) {
            if (arguments.length === 1) {
                arr.push(index);
            } else {
                index = Math.max(0, Math.min(arr.length, Number(index) || 0));
                arr.splice(index, 0, value);
            }
            return true;
        },
        addAll: function(values) {
            var incoming = values && typeof values.toArray === 'function' ? values.toArray() : Array.prototype.slice.call(values || []);
            for (var i = 0; i < incoming.length; i++) arr.push(incoming[i]);
            return incoming.length > 0;
        },
        get: function(index) { return arr[Number(index) || 0]; },
        set: function(index, value) { index = Number(index) || 0; var old = arr[index]; arr[index] = value; return old; },
        remove: function(value) {
            if (typeof value === 'number') return arr.splice(value, 1)[0];
            var index = arr.indexOf(value);
            if (index >= 0) { arr.splice(index, 1); return true; }
            return false;
        },
        size: function() { return arr.length; },
        isEmpty: function() { return arr.length === 0; },
        clear: function() { arr.length = 0; },
        contains: function(value) { return arr.indexOf(value) >= 0; },
        indexOf: function(value) { return arr.indexOf(value); },
        toArray: function() { return arr.slice(); },
        forEach: function(callback) { for (var i = 0; i < arr.length; i++) callback(arr[i], i); },
        iterator: function() {
            var index = 0;
            return {
                hasNext: function() { return index < arr.length; },
                next: function() { return arr[index++]; }
            };
        },
        toString: function() { return '[' + arr.map(__javaValueToString).join(', ') + ']'; }
    };
    return list;
}
function __qireaderCollectionBridgeFrom(items, options) {
    var arr = items && typeof items.toArray === 'function'
        ? Array.prototype.slice.call(items.toArray() || [])
        : Array.prototype.slice.call(items || []);
    var list = __javaArrayListFrom(arr);
    var bridgeOptions = options || {};
    var indexedLength = 0;

    function defineHidden(target, key, value) {
        try {
            Object.defineProperty(target, key, {
                value: value,
                enumerable: false,
                configurable: true,
                writable: true
            });
        } catch (_) {
            try { target[key] = value; } catch (_) {}
        }
    }

    function syncIndexes() {
        for (var i = 0; i < indexedLength; i++) delete list[i];
        for (var j = 0; j < arr.length; j++) list[j] = arr[j];
        indexedLength = arr.length;
    }

    function wrapMutator(name) {
        var original = list[name];
        if (typeof original !== 'function') return;
        defineHidden(list, name, function() {
            var result = original.apply(list, arguments);
            syncIndexes();
            return result;
        });
    }

    try {
        Object.defineProperty(list, 'length', {
            get: function() { return arr.length; },
            enumerable: false,
            configurable: true
        });
    } catch (_) {}

    if (typeof list.first !== 'function') {
        defineHidden(list, 'first', function() { return arr.length ? arr[0] : null; });
    }
    if (typeof list.last !== 'function') {
        defineHidden(list, 'last', function() { return arr.length ? arr[arr.length - 1] : null; });
    }
    if (typeof list.map !== 'function') {
        defineHidden(list, 'map', function(callback, thisArg) { return arr.map(callback, thisArg); });
    }
    if (typeof list.filter !== 'function') {
        defineHidden(list, 'filter', function(callback, thisArg) { return arr.filter(callback, thisArg); });
    }

    defineHidden(list, '__qireaderCollectionBridge', true);
    defineHidden(list, '__qireaderCollectionKind', String(bridgeOptions.kind || 'list'));
    defineHidden(list, 'toString', function() {
        return '[' + arr.map(__javaValueToString).join(', ') + ']';
    });
    defineHidden(list, 'valueOf', function() { return this.toString(); });

    wrapMutator('add');
    wrapMutator('addAll');
    wrapMutator('set');
    wrapMutator('remove');
    wrapMutator('clear');
    syncIndexes();
    return list;
}
if (!Packages.java.util.ArrayList) {
    Packages.java.util.ArrayList = function(initial) {
        if (initial && typeof initial.toArray === 'function') return __javaArrayListFrom(initial.toArray());
        if (initial && typeof initial.length === 'number' && typeof initial !== 'string') return __javaArrayListFrom(initial);
        return __javaArrayListFrom([]);
    };
    Packages.java.util.ArrayList.__javaClassName = 'ArrayList';
}
if (!Packages.java.util.HashMap) {
    Packages.java.util.HashMap = function(initial) {
        var map = {};
        var keys = [];
        function keyOf(key) { return String(key); }
        function remember(key) { if (keys.indexOf(key) < 0) keys.push(key); }
        var api = {
            put: function(key, value) { key = keyOf(key); var old = map.hasOwnProperty(key) ? map[key] : null; remember(key); map[key] = value; return old; },
            get: function(key) { key = keyOf(key); return map.hasOwnProperty(key) ? map[key] : null; },
            getOrDefault: function(key, def) { key = keyOf(key); return map.hasOwnProperty(key) ? map[key] : def; },
            remove: function(key) { key = keyOf(key); if (!map.hasOwnProperty(key)) return null; var old = map[key]; delete map[key]; keys = keys.filter(function(k) { return k !== key; }); return old; },
            containsKey: function(key) { return map.hasOwnProperty(keyOf(key)); },
            containsValue: function(value) { for (var i = 0; i < keys.length; i++) if (map[keys[i]] === value) return true; return false; },
            size: function() { return keys.length; },
            isEmpty: function() { return keys.length === 0; },
            clear: function() { map = {}; keys = []; },
            putAll: function(other) {
                if (!other) return;
                if (typeof other.entrySet === 'function') {
                    var entries = other.entrySet().toArray();
                    for (var i = 0; i < entries.length; i++) this.put(entries[i].getKey(), entries[i].getValue());
                } else {
                    for (var k in other) if (other.hasOwnProperty(k)) this.put(k, other[k]);
                }
            },
            keySet: function() { return __javaArrayListFrom(keys.slice()); },
            values: function() { return __javaArrayListFrom(keys.map(function(k) { return map[k]; })); },
            entrySet: function() {
                return __javaArrayListFrom(keys.map(function(k) {
                    return {
                        getKey: function() { return k; },
                        getValue: function() { return map[k]; },
                        toString: function() { return k + '=' + __javaValueToString(map[k]); }
                    };
                }));
            },
            toString: function() { return '{' + keys.map(function(k) { return k + '=' + __javaValueToString(map[k]); }).join(', ') + '}'; }
        };
        if (initial) api.putAll(initial);
        return api;
    };
    Packages.java.util.HashMap.__javaClassName = 'HashMap';
}
if (!Packages.java.util.LinkedHashMap) {
    Packages.java.util.LinkedHashMap = function(initial) {
        return new Packages.java.util.HashMap(initial);
    };
    Packages.java.util.LinkedHashMap.__javaClassName = 'LinkedHashMap';
}
if (!Packages.java.util.Base64) {
    Packages.java.util.Base64 = {
        getDecoder: function() {
            return {
                decode: function(input) {
                    var RootString = (typeof globalThis !== 'undefined' && globalThis.String) ? globalThis.String : String;
                    var str;
                    if (__javaIsStringLike(input)) {
                        str = RootString(input);
                    } else {
                        str = '';
                        for (var i = 0; i < input.length; i++) str += String.fromCharCode(input[i] & 0xFF);
                    }
                    return _nativeBase64DecodeToBytes(str);
                }
            };
        },
        getEncoder: function() {
            return {
                encode: function(input) {
                    var b64 = _nativeBase64Encode(Array.prototype.slice.call(input));
                    var bytes = [];
                    for (var i = 0; i < b64.length; i++) bytes.push(b64.charCodeAt(i));
                    return bytes;
                },
                encodeToString: function(input) {
                    return _nativeBase64Encode(Array.prototype.slice.call(input));
                }
            };
        }
    };
}
if (!Packages.java.util.Arrays) {
    Packages.java.util.Arrays = {
        copyOfRange: function(arr, from, to) {
            return Array.prototype.slice.call(arr, from, to);
        },
        copyOf: function(arr, newLength) {
            var result = Array.prototype.slice.call(arr, 0, newLength);
            while (result.length < newLength) result.push(0);
            return result;
        }
    };
}
Packages.java.util.concurrent = Packages.java.util.concurrent || {};
if (!Packages.java.util.concurrent.TimeUnit) {
    Packages.java.util.concurrent.TimeUnit = {
        MILLISECONDS: {
            sleep: function(ms) { Packages.java.lang.Thread.sleep(ms); },
            toMillis: function(value) { return Number(value) || 0; }
        },
        SECONDS: {
            sleep: function(seconds) { Packages.java.lang.Thread.sleep((Number(seconds) || 0) * 1000); },
            toMillis: function(value) { return (Number(value) || 0) * 1000; }
        }
    };
    Packages.java.util.concurrent.TimeUnit.__javaClassName = 'TimeUnit';
}
Packages.java.util.regex = Packages.java.util.regex || {};
if (!Packages.java.util.regex.Pattern) {
    Packages.java.util.regex.Pattern = {
        CASE_INSENSITIVE: 2,
        MULTILINE: 8,
        DOTALL: 32,
        quote: function(text) { return String(text).replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); },
        matches: function(pattern, input) { return this.compile(pattern).matcher(input).matches(); },
        compile: function(pattern, flags) {
            var jsFlags = 'g';
            flags = flags || 0;
            if (flags & 2) jsFlags += 'i';
            if (flags & 8) jsFlags += 'm';
            if (flags & 32) jsFlags += 's';
            var source = String(pattern);
            return {
                pattern: function() { return source; },
                matcher: function(input) {
                    input = String(input);
                    var regex = new RegExp(source, jsFlags);
                    var last = null;
                    return {
                        find: function() { last = regex.exec(input); return !!last; },
                        group: function(index) { index = index || 0; return last ? (last[index] !== undefined ? last[index] : null) : null; },
                        groupCount: function() { return last ? Math.max(0, last.length - 1) : 0; },
                        matches: function() { var r = new RegExp('^(?:' + source + ')$', jsFlags.replace('g', '')); last = r.exec(input); return !!last; },
                        replaceAll: function(replacement) { return input.replace(new RegExp(source, jsFlags), String(replacement)); },
                        replaceFirst: function(replacement) { return input.replace(new RegExp(source, jsFlags.replace('g', '')), String(replacement)); },
                        reset: function(newInput) { input = newInput === undefined ? input : String(newInput); regex.lastIndex = 0; last = null; return this; }
                    };
                },
                split: function(input) { return String(input).split(new RegExp(source, jsFlags.replace('g', ''))); },
                toString: function() { return source; }
            };
        }
    };
    Packages.java.util.regex.Pattern.__javaClassName = 'Pattern';
}

// ------ java.security ------
Packages.java.security = Packages.java.security || {};
if (!Packages.java.security.MessageDigest) {
    Packages.java.security.MessageDigest = {
        getInstance: function(algorithm) {
            var algorithmName = String(algorithm || 'MD5').toUpperCase().replace(/_/g, '-');
            var buffer = '';
            function bytesToString(data) {
                if (data === null || data === undefined) return '';
                if (typeof data === 'string') return data;
                var arr = Array.prototype.slice.call(data);
                if (typeof _nativeBytesToStr === 'function') return _nativeBytesToStr(arr, 'UTF-8');
                var s = '';
                for (var i = 0; i < arr.length; i++) s += String.fromCharCode(arr[i] & 0xFF);
                return s;
            }
            function hexToBytes(hex) {
                var out = [];
                for (var i = 0; i + 1 < hex.length; i += 2) out.push(parseInt(hex.substr(i, 2), 16));
                return out;
            }
            function digestHex(text) {
                if (typeof java !== 'undefined' && java.digestHex) return java.digestHex(text, algorithmName);
                if (algorithmName === 'MD5' && typeof java !== 'undefined' && java.md5Encode) return java.md5Encode(text);
                return '';
            }
            return {
                update: function(data) { buffer += bytesToString(data); },
                digest: function(data) { var text = data === undefined ? buffer : bytesToString(data); var bytes = hexToBytes(digestHex(text)); buffer = ''; return bytes; },
                reset: function() { buffer = ''; },
                getAlgorithm: function() { return algorithmName; }
            };
        },
        isEqual: function(a, b) {
            a = Array.prototype.slice.call(a || []);
            b = Array.prototype.slice.call(b || []);
            if (a.length !== b.length) return false;
            var diff = 0;
            for (var i = 0; i < a.length; i++) diff |= (a[i] ^ b[i]);
            return diff === 0;
        }
    };
    Packages.java.security.MessageDigest.__javaClassName = 'MessageDigest';
}
Packages.java.security.spec = Packages.java.security.spec || {};
Packages.java.security.interfaces = Packages.java.security.interfaces || {};
function __javaKeySpecBytes(bytes) {
    return Array.prototype.slice.call(bytes || []).map(function(v) { return Number(v) & 0xFF; });
}
if (!Packages.java.security.spec.PKCS8EncodedKeySpec) {
    Packages.java.security.spec.PKCS8EncodedKeySpec = function(bytes) {
        var encoded = __javaKeySpecBytes(bytes);
        return { getEncoded: function() { return encoded.slice(); }, _bytes: encoded, _format: 'PKCS8' };
    };
    Packages.java.security.spec.PKCS8EncodedKeySpec.__javaClassName = 'PKCS8EncodedKeySpec';
}
if (!Packages.java.security.spec.X509EncodedKeySpec) {
    Packages.java.security.spec.X509EncodedKeySpec = function(bytes) {
        var encoded = __javaKeySpecBytes(bytes);
        return { getEncoded: function() { return encoded.slice(); }, _bytes: encoded, _format: 'X509' };
    };
    Packages.java.security.spec.X509EncodedKeySpec.__javaClassName = 'X509EncodedKeySpec';
}
if (!Packages.java.security.KeyFactory) {
    Packages.java.security.KeyFactory = {
        getInstance: function(algorithm) {
            algorithm = String(algorithm || 'RSA').toUpperCase();
            function makeKey(spec, kind) {
                var bytes = spec && typeof spec.getEncoded === 'function' ? spec.getEncoded() : __javaKeySpecBytes(spec && spec._bytes ? spec._bytes : spec);
                return {
                    _algorithm: algorithm,
                    _kind: kind,
                    _keyBytes: bytes,
                    _keyBase64: _nativeBase64Encode(bytes),
                    getAlgorithm: function() { return algorithm; },
                    getEncoded: function() { return bytes.slice(); },
                    getFormat: function() { return spec && spec._format ? spec._format : ''; },
                    toString: function() { return algorithm + ' ' + kind + ' key'; }
                };
            }
            return {
                generatePrivate: function(spec) { return makeKey(spec, 'private'); },
                generatePublic: function(spec) { return makeKey(spec, 'public'); }
            };
        }
    };
    Packages.java.security.KeyFactory.__javaClassName = 'KeyFactory';
}
if (!Packages.java.security.Signature) {
    Packages.java.security.Signature = {
        getInstance: function(algorithm) {
            algorithm = String(algorithm || 'SHA256WithRSA');
            var privateKey = null;
            var publicKey = null;
            var buffer = [];
            function appendBytes(data) {
                if (data === null || data === undefined) return;
                if (typeof data === 'string') data = data.getBytes ? data.getBytes('UTF-8') : String(data).split('').map(function(c) { return c.charCodeAt(0); });
                var arr = Array.prototype.slice.call(data);
                for (var i = 0; i < arr.length; i++) buffer.push(Number(arr[i]) & 0xFF);
            }
            function bufferedString() {
                if (typeof _nativeBytesToStr === 'function') return _nativeBytesToStr(buffer, 'UTF-8');
                var s = '';
                for (var i = 0; i < buffer.length; i++) s += String.fromCharCode(buffer[i]);
                return s;
            }
            return {
                initSign: function(key) { privateKey = key; buffer = []; },
                initVerify: function(key) { publicKey = key; buffer = []; },
                update: function(data) { appendBytes(data); },
                sign: function() {
                    if (!privateKey || !privateKey._keyBase64 || typeof java === 'undefined' || typeof java.createSign !== 'function') return [];
                    var signed = java.createSign(algorithm).setPrivateKey(privateKey._keyBase64).signBase64(bufferedString());
                    return _nativeBase64DecodeToBytes(signed || '');
                },
                verify: function(signature) {
                    if (!publicKey || !publicKey._keyBase64 || typeof java === 'undefined' || typeof java.createSign !== 'function') return false;
                    var sigB64 = _nativeBase64Encode(Array.prototype.slice.call(signature || []));
                    return !!java.createSign(algorithm).setPublicKey(publicKey._keyBase64).verify(bufferedString(), sigB64);
                },
                getAlgorithm: function() { return algorithm; }
            };
        }
    };
    Packages.java.security.Signature.__javaClassName = 'Signature';
}

// ------ java.io (最小存根) ------
Packages.java.io = Packages.java.io || {};
function __qireaderZeroBytes(length) {
    length = Math.max(0, Number(length) || 0);
    var arr = new Array(length);
    for (var i = 0; i < length; i++) arr[i] = 0;
    return arr;
}
function __qireaderNormalizeBytes(bytes) {
    if (!bytes) return [];
    return Array.prototype.slice.call(bytes).map(function(value) {
        return Number(value) & 0xFF;
    });
}
function __qireaderByteStream(bytes) {
    var source = __qireaderNormalizeBytes(bytes);
    return {
        _bytes: source,
        _pos: 0,
        read: function(target, offset, length) {
            if (arguments.length === 0) {
                if (this._pos >= this._bytes.length) return -1;
                return this._bytes[this._pos++] & 0xFF;
            }
            if (!target || typeof target.length !== 'number') return -1;
            offset = arguments.length > 1 ? Math.max(0, Number(offset) || 0) : 0;
            length = arguments.length > 2 ? Math.max(0, Number(length) || 0) : (target.length - offset);
            length = Math.min(length, Math.max(0, target.length - offset));
            if (length === 0) return 0;
            var remaining = this._bytes.length - this._pos;
            if (remaining <= 0) return -1;
            var count = Math.min(length, remaining);
            for (var i = 0; i < count; i++) {
                target[offset + i] = this._bytes[this._pos++] & 0xFF;
            }
            return count;
        },
        skip: function(count) {
            count = Math.max(0, Number(count) || 0);
            var skipped = Math.min(count, Math.max(0, this._bytes.length - this._pos));
            this._pos += skipped;
            return skipped;
        },
        available: function() {
            return Math.max(0, this._bytes.length - this._pos);
        },
        close: function() {},
        toByteArray: function() {
            return this._bytes.slice(this._pos);
        }
    };
}
if (!Packages.java.io.IOException) {
    Packages.java.io.IOException = function(message) {
        var error = new Error(String(message || ''));
        error.name = 'IOException';
        error.getMessage = function() { return error.message; };
        return error;
    };
    Packages.java.io.IOException.__javaClassName = 'IOException';
}
if (!Packages.java.io.ByteArrayInputStream) {
    Packages.java.io.ByteArrayInputStream = function(bytes) {
        return __qireaderByteStream(bytes);
    };
    Packages.java.io.ByteArrayInputStream.__javaClassName = 'ByteArrayInputStream';
}
if (!Packages.java.io.ByteArrayOutputStream) {
    Packages.java.io.ByteArrayOutputStream = function() {
        var buf = [];
        return {
            write: function(b, offset, length) {
                if (b === null || b === undefined) return;
                if (Array.isArray(b) || (typeof b === 'object' && typeof b.length === 'number')) {
                    var values = __qireaderNormalizeBytes(b);
                    var start = arguments.length > 1 ? Math.max(0, Number(offset) || 0) : 0;
                    var end = arguments.length > 2 ? Math.min(values.length, start + Math.max(0, Number(length) || 0)) : values.length;
                    for (var i = start; i < end; i++) buf.push(values[i] & 0xFF);
                    return;
                }
                buf.push(Number(b) & 0xFF);
            },
            toByteArray: function() { return buf; },
            reset: function() { buf = []; },
            close: function() {}
        };
    };
    Packages.java.io.ByteArrayOutputStream.__javaClassName = 'ByteArrayOutputStream';
}
if (!Packages.java.io.BufferedInputStream) {
    Packages.java.io.BufferedInputStream = function(input) {
        var stream = input || __qireaderByteStream([]);
        return {
            read: function(target, offset, length) {
                if (!stream || typeof stream.read !== 'function') return -1;
                if (arguments.length === 0) return stream.read();
                if (arguments.length === 1) return stream.read(target);
                if (arguments.length === 2) return stream.read(target, offset);
                return stream.read(target, offset, length);
            },
            skip: function(count) {
                if (!stream || typeof stream.skip !== 'function') return 0;
                return stream.skip(count);
            },
            available: function() {
                if (!stream || typeof stream.available !== 'function') return 0;
                return stream.available();
            },
            close: function() {
                if (stream && typeof stream.close === 'function') stream.close();
            },
            toByteArray: function() {
                if (stream && typeof stream.toByteArray === 'function') return stream.toByteArray();
                return [];
            }
        };
    };
    Packages.java.io.BufferedInputStream.__javaClassName = 'BufferedInputStream';
}
if (!Packages.java.io.InputStreamReader) {
    Packages.java.io.InputStreamReader = function(input, charset) {
        var bytes = input && input._bytes ? input._bytes : [];
        var text = typeof _nativeBytesToStr === 'function' ? _nativeBytesToStr(Array.prototype.slice.call(bytes), charset || 'UTF-8') : '';
        var offset = 0;
        return {
            read: function() { return offset < text.length ? text.charCodeAt(offset++) : -1; },
            close: function() {},
            toString: function() { return text; }
        };
    };
}

// ------ java.util.zip ------
Packages.java.util = Packages.java.util || {};
Packages.java.util.zip = Packages.java.util.zip || {};
if (!Packages.java.util.zip.GZIPInputStream) {
    Packages.java.util.zip.GZIPInputStream = function(input) {
        var rawBytes = [];
        if (input && typeof input.toByteArray === 'function') {
            rawBytes = __qireaderNormalizeBytes(input.toByteArray());
        } else if (input && typeof input.read === 'function') {
            var temp = __qireaderZeroBytes(1024);
            var read;
            while ((read = input.read(temp)) > 0) {
                for (var i = 0; i < read; i++) rawBytes.push(temp[i] & 0xFF);
            }
        }
        var decompressed = typeof _nativeGunzip === 'function' ? _nativeGunzip(rawBytes) : rawBytes;
        var stream = __qireaderByteStream(decompressed);
        return {
            read: function(target, offset, length) {
                if (arguments.length === 0) return stream.read();
                if (arguments.length === 1) return stream.read(target);
                if (arguments.length === 2) return stream.read(target, offset);
                return stream.read(target, offset, length);
            },
            skip: function(count) {
                return stream.skip(count);
            },
            available: function() {
                return stream.available();
            },
            close: function() {},
            toByteArray: function() {
                return stream.toByteArray();
            }
        };
    };
    Packages.java.util.zip.GZIPInputStream.__javaClassName = 'GZIPInputStream';
}

// ------ java.nio ------
Packages.java.nio = Packages.java.nio || {};
if (!Packages.java.nio.ByteBuffer) {
    Packages.java.nio.ByteBuffer = {
        allocate: function(length) {
            var storage = __qireaderZeroBytes(length);
            return {
                array: function() { return storage; }
            };
        },
        wrap: function(bytes) {
            var storage = __qireaderNormalizeBytes(bytes);
            return {
                array: function() { return storage; }
            };
        }
    };
    Packages.java.nio.ByteBuffer.__javaClassName = 'ByteBuffer';
}

// ------ android.util.Base64 ------
// ------ java.net.URL (模拟 Java URL 类) ------
Packages.java.net = Packages.java.net || {};
if (!Packages.java.net.URL) {
    Packages.java.net.URL = function(urlStr) {
        var m = String(urlStr).match(/^(https?):\/\/([^:\/\?#]+)(?::(\d+))?(\/[^?#]*)?(?:\?([^#]*))?(?:#(.*))?/);
        var protocol = m ? m[1] : '';
        var host = m ? m[2] : '';
        var port = m && m[3] ? parseInt(m[3]) : -1;
        var path = m && m[4] ? m[4] : '/';
        var query = m && m[5] ? m[5] : '';
        var ref = m && m[6] ? m[6] : null;
        return {
            protocol: protocol,
            host: host,
            port: port,
            path: path,
            query: query,
            ref: ref,
            getProtocol: function() { return protocol; },
            getHost: function() { return host; },
            getPort: function() { return port; },
            getPath: function() { return path; },
            getQuery: function() { return query; },
            getRef: function() { return ref; },
            toString: function() { return String(urlStr); }
        };
    };
}
if (!Packages.java.net.URLEncoder) {
    Packages.java.net.URLEncoder = {
        encode: function(value, charset) {
            var RootString = (typeof globalThis !== 'undefined' && globalThis.String) ? globalThis.String : String;
            var bytes = _nativeStrToBytes(RootString(value), charset || 'UTF-8');
            var out = '';
            var hex = '0123456789ABCDEF';
            for (var i = 0; i < bytes.length; i++) {
                var b = bytes[i] & 0xFF;
                if (b === 0x20) {
                    out += '+';
                } else if ((b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || b === 0x2A || b === 0x2D || b === 0x2E || b === 0x5F) {
                    out += RootString.fromCharCode(b);
                } else {
                    out += '%' + hex[(b >> 4) & 0xF] + hex[b & 0xF];
                }
            }
            return out;
        }
    };
    Packages.java.net.URLEncoder.__javaClassName = 'URLEncoder';
}
if (!Packages.java.net.URLDecoder) {
    Packages.java.net.URLDecoder = {
        decode: function(value, charset) {
            var RootString = (typeof globalThis !== 'undefined' && globalThis.String) ? globalThis.String : String;
            var text = RootString(value);
            var bytes = [];
            for (var i = 0; i < text.length; i++) {
                var ch = text.charAt(i);
                if (ch === '+') {
                    bytes.push(0x20);
                } else if (ch === '%' && i + 2 < text.length) {
                    var hex = text.substr(i + 1, 2);
                    var b = parseInt(hex, 16);
                    if (!isNaN(b)) {
                        bytes.push(b & 0xFF);
                        i += 2;
                    } else {
                        bytes.push(ch.charCodeAt(0) & 0xFF);
                    }
                } else {
                    var raw = _nativeStrToBytes(ch, charset || 'UTF-8');
                    for (var j = 0; j < raw.length; j++) bytes.push(raw[j] & 0xFF);
                }
            }
            return _nativeBytesToStr(bytes, charset || 'UTF-8');
        }
    };
    Packages.java.net.URLDecoder.__javaClassName = 'URLDecoder';
}

// ------ java.math ------
Packages.java.math = Packages.java.math || {};
if (!Packages.java.math.BigInteger) {
    Packages.java.math.BigInteger = function(value, radix) {
        var n = parseInt(String(value || '0'), radix || 10);
        if (!isFinite(n)) n = 0;
        return {
            intValue: function() { return n | 0; },
            longValue: function() { return n; },
            toString: function(outRadix) { return Math.trunc(n).toString(outRadix || 10); }
        };
    };
    Packages.java.math.BigInteger.__javaClassName = 'BigInteger';
}

// ------ android.util.Base64 ------
Packages.android = Packages.android || {};
Packages.android.util = Packages.android.util || {};
if (!Packages.android.util.Base64 || !Packages.android.util.Base64.decode) {
    Packages.android.util.Base64 = {
        DEFAULT: 0,
        NO_WRAP: 2,
        NO_PADDING: 1,
        URL_SAFE: 8,
        decode: function(input, flags) {
            var RootString = (typeof globalThis !== 'undefined' && globalThis.String) ? globalThis.String : String;
            var str;
            if (__javaIsStringLike(input)) {
                str = RootString(input);
            } else {
                str = '';
                for (var i = 0; i < input.length; i++) str += String.fromCharCode(input[i] & 0xFF);
            }
            return _nativeBase64DecodeToBytes(str);
        },
        encode: function(input, flags) {
            var b64 = _nativeBase64Encode(Array.prototype.slice.call(input));
            var bytes = [];
            for (var i = 0; i < b64.length; i++) bytes.push(b64.charCodeAt(i));
            return bytes;
        },
        encodeToString: function(input, flags) {
            return _nativeBase64Encode(Array.prototype.slice.call(input));
        }
    };
}

// ------ android.text.TextUtils ------
Packages.android.text = Packages.android.text || {};
if (!Packages.android.text.TextUtils) {
    Packages.android.text.TextUtils = {
        isEmpty: function(s) { return s === null || s === undefined || String(s) === ''; },
        join: function(delimiter, tokens) {
            if (!tokens) return '';
            return Array.prototype.slice.call(tokens).join(String(delimiter));
        }
    };
}

// ------ android.graphics (最小存根，图片处理无法在 JSC 实现) ------
Packages.android.graphics = Packages.android.graphics || {};
if (!Packages.android.graphics.BitmapFactory) {
    Packages.android.graphics.BitmapFactory = {
        decodeStream: function() { return null; },
        decodeByteArray: function() { return null; }
    };
}

// ------ cn.hutool ------
Packages.cn = Packages.cn || {};
Packages.cn.hutool = Packages.cn.hutool || {};
Packages.cn.hutool.core = Packages.cn.hutool.core || {};
Packages.cn.hutool.core.codec = Packages.cn.hutool.core.codec || {};
if (!Packages.cn.hutool.core.codec.Base64) {
    Packages.cn.hutool.core.codec.Base64 = {
        encode: function(data) {
            if (typeof data === 'string') return java.base64Encode(data);
            return _nativeBase64Encode(Array.prototype.slice.call(data));
        },
        decode: function(data) {
            return _nativeBase64DecodeToBytes(String(data));
        },
        decodeStr: function(data) {
            return java.base64Decode(String(data));
        }
    };
}
Packages.cn.hutool.core.util = Packages.cn.hutool.core.util || {};
if (!Packages.cn.hutool.core.util.StrUtil) {
    Packages.cn.hutool.core.util.StrUtil = {
        reverse: function(str) {
            return String(str).split('').reverse().join('');
        },
        isEmpty: function(str) {
            return str === null || str === undefined || String(str) === '';
        },
        isNotEmpty: function(str) {
            return !this.isEmpty(str);
        },
        isBlank: function(str) {
            return this.isEmpty(str) || String(str).trim() === '';
        },
        isNotBlank: function(str) {
            return !this.isBlank(str);
        }
    };
}
if (!Packages.cn.hutool.core.util.ZipUtil) {
    Packages.cn.hutool.core.util.ZipUtil = {
        unGzip: function(data) {
            return _nativeGunzip(Array.prototype.slice.call(data));
        },
        gzip: function(data, charset) {
            if (typeof data === 'string') {
                data = data.getBytes ? data.getBytes(charset || 'UTF-8') : data.split('').map(function(c) { return c.charCodeAt(0); });
            }
            if (typeof _nativeGzip === 'function') {
                return _nativeGzip(Array.prototype.slice.call(data));
            }
            return data;
        }
    };
}
Packages.cn.hutool.crypto = Packages.cn.hutool.crypto || {};
Packages.cn.hutool.crypto.digest = Packages.cn.hutool.crypto.digest || {};
if (!Packages.cn.hutool.crypto.digest.DigestUtil) {
    Packages.cn.hutool.crypto.digest.DigestUtil = {
        md5: function(data) {
            function hexToBytes(hex) {
                var out = [];
                for (var i = 0; i + 1 < hex.length; i += 2) {
                    out.push(parseInt(hex.substr(i, 2), 16));
                }
                return out;
            }
            if (typeof data === 'object' && data.length !== undefined) {
                var s = '';
                for (var i = 0; i < data.length; i++) s += String.fromCharCode(data[i] & 0xFF);
                return hexToBytes(java.md5Encode(s));
            }
            return hexToBytes(java.md5Encode(String(data)));
        },
        md5Hex: function(data) {
            if (typeof data === 'object' && data.length !== undefined) {
                var s = '';
                for (var i = 0; i < data.length; i++) s += String.fromCharCode(data[i] & 0xFF);
                return java.md5Encode(s);
            }
            return java.md5Encode(String(data));
        }
    };
}

// ------ io.legado.app.help.http.StrResponse ------
Packages.io = Packages.io || {};
Packages.io.legado = Packages.io.legado || {};
Packages.io.legado.app = Packages.io.legado.app || {};
Packages.io.legado.app.help = Packages.io.legado.app.help || {};
Packages.io.legado.app.help.http = Packages.io.legado.app.help.http || {};
if (!Packages.io.legado.app.help.http.StrResponse) {
    Packages.io.legado.app.help.http.StrResponse = function(url, body) {
        var _url = url || '';
        var _body = (body !== undefined && body !== null) ? String(body) : '';
        return {
            url: function() { return _url; },
            body: function() { return _body; },
            toString: function() { return _body; }
        };
    };
}

// ------ org.jsoup (链接已有 Jsoup 桥接) ------
Packages.org = Packages.org || {};
Packages.org.jsoup = Packages.org.jsoup || {};
if (typeof org !== 'undefined' && org.jsoup && org.jsoup.Jsoup) {
    Packages.org.jsoup.Jsoup = org.jsoup.Jsoup;
}
Packages.org.jsoup.nodes = Packages.org.jsoup.nodes || {};
Packages.org.jsoup.nodes.Document = Packages.org.jsoup.nodes.Document || function() {};
Packages.org.jsoup.nodes.Element = Packages.org.jsoup.nodes.Element || function() {};

// ------ okhttp3 (最小存根，使用 java.ajax 桥接) ------

/**
 * okhttp3 stub 用的取数函数。
 *
 * ⚠️⚠️ **这个函数以前根本没定义**（用了没声明 → 运行时 ReferenceError）：
 *    eslint 的 no-undef 扫出来的（其它门禁都抓不到 —— JS 的未声明变量
 *    只有运行时才炸，而 node 的 vm 上下文用 Proxy 拦全局对象，
 *    严格模式对未声明变量赋值**根本不抛** → jsdom 永远测不出来）。
 *    ⇒ 任何用到 okhttp3 的书源都会在运行时炸。
 *
 * 用引擎自己的请求通道：`java.ajax(url + ',{json}')`
 * （两遍跑机制认这个 `,{json}` 后缀，会把 method/headers/body 带去真请求）✅
 */
function _jsoupConnectFetch(url, method, body, headersJson) {
  var opts = { method: String(method || 'GET') };
  try {
    var h = JSON.parse(headersJson || '{}');
    if (h && typeof h === 'object' && Object.keys(h).length) opts.headers = h;
  } catch (e) { /* 头解析不了就算了 */ }
  if (body) opts.body = String(body);
  var full = String(url) + ',' + JSON.stringify(opts);
  var resp = '';
  try { resp = String(java.ajax(full)); } catch (e) { resp = ''; }
  return {
    body: resp,
    bytes: [],
    code: resp ? 200 : 0,
    url: String(url),
    headers: {}
  };
}

Packages.okhttp3 = Packages.okhttp3 || {};
if (!Packages.okhttp3.OkHttpClient) {
    Packages.okhttp3.OkHttpClient = function() {
        return {
            newCall: function(request) {
                return {
                    execute: function() {
                        var hJson = JSON.stringify(request._headers || {});
                        var resp = _jsoupConnectFetch(request._url, request._method || 'GET', request._body || '', hJson);
                        var respHeaders = resp.headers || {};
                        return {
                            _body: resp.body || '',
                            _bytes: resp.bytes || [],
                            _code: resp.code || 0,
                            _url: request._url,
                            _headers: respHeaders,
                            body: function() {
                                var self = this;
                                return {
                                    string: function() { return self._body; },
                                    bytes: function() { return self._bytes; },
                                    contentType: function() { return null; },
                                    close: function() {}
                                };
                            },
                            code: function() { return this._code; },
                            headers: function() {
                                var h = this._headers;
                                return {
                                    _map: h,
                                    get: function(name) { return h[name] || h[name.toLowerCase()] || null; },
                                    names: function() {
                                        var arr = [];
                                        for (var k in h) { if (h.hasOwnProperty(k)) arr.push(k); }
                                        // 添加 forEach 支持
                                        arr.forEach = arr.forEach || Array.prototype.forEach;
                                        return arr;
                                    }
                                };
                            },
                            close: function() {},
                            isSuccessful: function() { return this._code >= 200 && this._code < 300; }
                        };
                    }
                };
            }
        };
    };
    Packages.okhttp3.Request = {
        Builder: function() {
            var _url = '', _method = 'GET', _body = '', _headers = {};
            return {
                url: function(u) { _url = String(u); return this; },
                get: function() { _method = 'GET'; return this; },
                post: function(body) { _method = 'POST'; _body = body ? body._content || '' : ''; return this; },
                addHeader: function(name, value) { _headers[name] = value; return this; },
                header: function(name, value) { _headers[name] = value; return this; },
                build: function() { return { _url: _url, _method: _method, _body: _body, _headers: _headers }; }
            };
        }
    };
    Packages.okhttp3.RequestBody = {
        create: function(contentType, content) {
            return { _content: String(content || '') };
        }
    };
    Packages.okhttp3.MediaType = {
        parse: function(type) { return { _type: type }; }
    };
}

// ====== Rhino Java String 兼容方法 ======
// String.prototype 补充 Java String 兼容方法
if (!String.prototype.isEmpty) {
    String.prototype.isEmpty = function() { return this.length === 0; };
}
if (!String.prototype.contains) {
    String.prototype.contains = function(s) { return this.indexOf(s) >= 0; };
}
if (!String.prototype.equals) {
    String.prototype.equals = function(other) { return this.valueOf() === String(other); };
}
if (!String.prototype.equalsIgnoreCase) {
    String.prototype.equalsIgnoreCase = function(other) { return this.toLowerCase() === String(other).toLowerCase(); };
}

// 让脚本的顶层完成值是 undefined：WebKit 的 evaluateJavaScript 会把完成值
// 桥接回 Swift，普通 JS 对象/函数/Symbol 桥接不了 →
// WKError.resultTypeIsUnsupported → 轻阅报「引擎脚本执行出错」，整个引擎起不来。
// 栖阅原文件没有这行（它不走 evaluateJavaScript 返回值桥接），移植后必须补。
;void 0;
