import Foundation

/// Per-analysis variable bag shared between rules and JS (`java.put/get`, `@put/@get`, `{{}}`).
public final class RuleVariables {
    public var map: [String: String] = [:]
    private let lock = NSLock()
    public init() {}

    public func put(_ key: String, _ value: String) {
        lock.lock(); map[key] = value; lock.unlock()
    }
    public func get(_ key: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return map[key] ?? ""
    }

    /// JS `putVariable`: accepts a JSON object string, merges into map.
    public func putVariable(_ jsonOrKey: String, _ value: String? = nil) {
        if let value { put(jsonOrKey, value); return }
        guard let d = jsonOrKey.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        for (k, v) in o { put(k, "\(v)") }
    }
    /// JS `getVariable()`: whole map as JSON; `getVariable(key)`: single value.
    public func getVariable(_ key: String? = nil) -> String {
        if let key { return get(key) }
        lock.lock(); let m = map; lock.unlock()
        guard let d = try? JSONSerialization.data(withJSONObject: m) else { return "{}" }
        return String(data: d, encoding: .utf8) ?? "{}"
    }
    public func setVariable(_ json: String) {
        lock.lock(); map.removeAll(); lock.unlock()
        putVariable(json)
    }
}