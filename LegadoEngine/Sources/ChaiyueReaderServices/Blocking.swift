import Foundation

/// 在 GCD 线程上执行同步的网络或文件操作，避免长时间占用 Swift 并发的协作线程
func offload<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result(catching: body))
        }
    }
}
