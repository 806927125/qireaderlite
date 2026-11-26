import Foundation

public struct TimeoutError: LocalizedError, Sendable {
    public init() {}
    public var errorDescription: String? { "请求超时" }
}

/// 带超时执行异步操作。超时或外层取消时立即返回，并取消底层任务；
/// 不等待底层任务真正结束（规则引擎的工作线程会在检查取消标记时自行退出）。
public func withTimeout<T: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let gate = ResumeGate<T>()
    let worker = Task { try await operation() }
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            gate.attach(continuation)
            let timer = Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                if gate.resume(.failure(TimeoutError())) { worker.cancel() }
            }
            Task {
                let result = await worker.result
                timer.cancel()
                gate.resume(result)
            }
        }
    } onCancel: {
        worker.cancel()
        gate.resume(.failure(CancellationError()))
    }
}

/// 保证 continuation 只被恢复一次；恢复先于挂接时暂存结果
final class ResumeGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?
    private var finished = false

    func attach(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let pending {
            self.pending = nil
            lock.unlock()
            continuation.resume(with: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    @discardableResult
    func resume(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return false
        }
        finished = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            pending = result
            lock.unlock()
        }
        return true
    }
}
