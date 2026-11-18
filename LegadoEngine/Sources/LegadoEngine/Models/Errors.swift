import Foundation

/// Error type used across the engine.
public struct LegadoError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var localizedDescription: String { message }
}

// MARK: - Lenient decoding helpers (book-source JSON in the wild mixes strings/numbers/bools)

extension KeyedDecodingContainer {
    func lenientString(_ key: K) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? decodeIfPresent(Int64.self, forKey: key) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) {
            return d == d.rounded() ? String(Int64(d)) : String(d)
        }
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b ? "true" : "false" }
        return nil
    }
    func lenientInt(_ key: K) -> Int? {
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Int(s.trimmingCharacters(in: .whitespaces)) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        return nil
    }
    func lenientInt64(_ key: K) -> Int64? {
        if let i = try? decodeIfPresent(Int64.self, forKey: key) { return i }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Int64(s.trimmingCharacters(in: .whitespaces)) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int64(d) }
        return nil
    }
    func lenientBool(_ key: K) -> Bool? {
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b }
        if let s = try? decodeIfPresent(String.self, forKey: key) {
            switch s.lowercased() { case "true", "1": return true; case "false", "0": return false; default: return nil }
        }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i != 0 }
        return nil
    }
}