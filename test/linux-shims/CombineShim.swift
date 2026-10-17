// Linux 上没有 Combine / SwiftUI / WebKit，这里给最小 shim，
// 目的只有一个：让 Foundation 那层能被 swiftc 真正类型检查。
// 这些 shim 不追求行为一致，只求签名能通过。
//
// 覆盖范围：书源模型、书籍模型、存储层、SourceService（含全部 DTO）。
// 覆盖不到：RuleSandbox.swift（WebKit/UIKit）、各 SwiftUI 页面。

import Foundation

// MARK: - Combine

public protocol ObservableObject: AnyObject {}

@propertyWrapper
public struct Published<Value> {
    private var storage: Value
    public init(wrappedValue: Value) { self.storage = wrappedValue }
    public var wrappedValue: Value {
        get { storage }
        set { storage = newValue }
    }
    public var projectedValue: Published<Value> { self }
}

