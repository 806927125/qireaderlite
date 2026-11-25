#if canImport(Crypto)
import Crypto
#elseif canImport(CryptoKit)
import CryptoKit
#endif
import Foundation
import Observation

/// 本地神经语音模型包（约 370 MB）：取服务器上的 manifest.json 后交给 VoicePackTransfer 后台下载，
/// 界面只读这里的进度与状态
@Observable
final class LocalVoiceStore {
    enum Phase: Equatable { case missing, downloading, ready, failed(String) }

    /// 模型目录地址，需包含 manifest.json（由 App/Tools/fetch_kokoro.sh 生成）
    static var baseURL: URL {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "voicePackURL"), let url = URL(string: raw) { return url }
        #endif
        return URL(string: "https://mono.zijiu522.cn/qingjian/kokoro-v1.1/")!
    }

    static var directory: URL { VoicePackTransfer.directory }
    static var isReady: Bool { VoicePackTransfer.isReady }

    private(set) var phase: Phase
    private(set) var received: Int64 = 0
    private(set) var total: Int64 = 0
    @ObservationIgnored private var preparing: Task<Void, Never>?
    /// 取消、删除、开始时递增，早于它的进度回报作废
    @ObservationIgnored private var epoch = 0

    init() {
        phase = Self.isReady ? .ready : .missing
        let transfer = VoicePackTransfer.shared
        transfer.observe { snapshot in
            Task { @MainActor in self.apply(snapshot) }
        }
        transfer.connect()
    }

    var progress: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }

    /// 下载过一部分、尚未完成
    var isPartial: Bool { phase != .ready && received > 0 }

    func download() {
        guard phase != .downloading else { return }
        phase = .downloading
        preparing = Task { await prepare() }
    }

    func cancel() {
        preparing?.cancel()
        preparing = nil
        epoch = VoicePackTransfer.shared.cancel()
        phase = Self.isReady ? .ready : .missing
    }

    func remove() {
        preparing?.cancel()
        preparing = nil
        epoch = VoicePackTransfer.shared.remove()
        received = 0
        total = 0
        phase = .missing
    }

    private func prepare() async {
        do {
            let base = Self.baseURL
            let (data, response) = try await URLSession.shared.data(from: base.appendingPathComponent("manifest.json"))
            // 站点对不存在的路径回退到 index.html，同样按地址不可用处理
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let manifest = try? JSONDecoder().decode(VoicePackTransfer.Manifest.self, from: data) else {
                throw URLError(.resourceUnavailable)
            }
            guard !Task.isCancelled else { return }
            total = manifest.files.reduce(0) { $0 + $1.size }
            epoch = VoicePackTransfer.shared.start(base: base, manifest: manifest)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(error is URLError ? "语音包地址不可用" : error.localizedDescription)
        }
        preparing = nil
    }

    private func apply(_ snapshot: VoicePackTransfer.Snapshot) {
        guard snapshot.epoch >= epoch else { return }
        received = snapshot.received
        if snapshot.total > 0 { total = snapshot.total }
        switch snapshot.state {
        case .running: phase = .downloading
        case .done: phase = .ready
        case .failed(let message): phase = .failed(message)
        case .idle: break
        }
    }
}

/// 语音包后台下载：文件按 8 MB 分块，分到 4 个后台 URLSession 并发请求。
/// App 退到后台或被挂起时由系统继续下载；回到前台或被系统唤醒时把完成的块写入 .part 对应偏移，
/// 完成的块序号记在 .parts；被强退时用续传数据接着下。每个文件写满后校验 SHA-256 再改名。
/// 状态只在串行的 delegate 队列上读写，锁只保护会话、回调与 epoch
nonisolated final class VoicePackTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct File: Codable, Sendable {
        let name: String
        let size: Int64
        let sha256: String
    }

    struct Manifest: Codable, Sendable {
        let version: String
        let files: [File]
    }

    enum State: Equatable, Sendable { case idle, running, done, failed(String) }

    struct Snapshot: Sendable {
        let epoch: Int
        let received: Int64
        let total: Int64
        let state: State
    }

    static let shared = VoicePackTransfer()
    private static let chunk: Int64 = 8 << 20
    private static let lanes = 4
    private static let prefix = "com.linchengbo.chaiyue.voicepack."

    static var directory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Kokoro", isDirectory: true)
    }

    private static var marker: URL { directory.appendingPathComponent(".ready") }
    private static var planURL: URL { directory.appendingPathComponent("plan.json") }

    static var isReady: Bool { FileManager.default.fileExists(atPath: marker.path) }

    private struct Plan: Codable {
        let base: URL
        let manifest: Manifest
    }

    private struct Parts: Codable {
        let chunk: Int64
        let done: Set<Int>
    }

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    private let lock = NSLock()
    private var sessions: [URLSession] = []
    private var observer: (@Sendable (Snapshot) -> Void)?
    private var handlers: [String: () -> Void] = [:]
    private var epoch = 0

    private var plan: Plan?
    private var done: [String: Set<Int>] = [:]
    private var complete: Set<String> = []
    private var inflight: [String: Int64] = [:]
    private var retries: [String: Int] = [:]
    private var cancelled: Set<String> = []
    private var state: State = .idle
    private var lastNotify = Date.distantPast

    // MARK: - 对外

    func observe(_ observer: @escaping @Sendable (Snapshot) -> Void) {
        lock.withLock { self.observer = observer }
        queue.addOperation { [self] in notify(force: true) }
    }

    /// 重建后台会话以接回系统里仍在进行或已完成的任务
    func connect() {
        let created = lock.withLock {
            guard sessions.isEmpty else { return false }
            sessions = (0..<Self.lanes).map { lane in
                let config = URLSessionConfiguration.background(withIdentifier: Self.prefix + "\(lane)")
                config.sessionSendsLaunchEvents = true
                config.isDiscretionary = false
                config.httpMaximumConnectionsPerHost = 2
                return URLSession(configuration: config, delegate: self, delegateQueue: queue)
            }
            return true
        }
        guard created else { return }
        queue.addOperation { [self] in
            if let data = try? Data(contentsOf: Self.planURL), let plan = try? JSONDecoder().decode(Plan.self, from: data) {
                self.plan = plan
                load(plan)
            }
            allTasks { [self] tasks in
                if !tasks.isEmpty, state == .idle { state = .running }
                notify(force: true)
            }
        }
    }

    func handleEvents(_ identifier: String, completion: @escaping () -> Void) {
        guard identifier.hasPrefix(Self.prefix) else {
            completion()
            return
        }
        lock.withLock { handlers[identifier] = completion }
        connect()
    }

    @discardableResult
    func start(base: URL, manifest: Manifest) -> Int {
        connect()
        let epoch = bump()
        queue.addOperation { [self] in
            let plan = Plan(base: base, manifest: manifest)
            do {
                try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var excluded = Self.directory
                try? excluded.setResourceValues(values)
                try JSONEncoder().encode(plan).write(to: Self.planURL)
            } catch {
                fail("无法写入语音包")
                return
            }
            try? FileManager.default.removeItem(at: Self.marker)
            self.plan = plan
            load(plan)
            retries = [:]
            state = .running
            allTasks { [self] tasks in
                let pending = Set(tasks.filter { $0.state == .running || $0.state == .suspended }.compactMap(\.taskDescription))
                let sessions = lock.withLock { self.sessions }
                var lane = 0
                for file in plan.manifest.files where !complete.contains(file.name) {
                    for index in 0..<chunks(file) where done[file.name]?.contains(index) != true {
                        let key = "\(file.name)#\(index)"
                        guard !pending.contains(key) else { continue }
                        enqueue(key, file: file, index: index, session: sessions[lane % sessions.count])
                        lane += 1
                    }
                }
                finishIfComplete()
                notify(force: true)
            }
        }
        return epoch
    }

    @discardableResult
    func cancel() -> Int {
        let epoch = bump()
        queue.addOperation { [self] in
            if state == .running { state = .idle }
            inflight = [:]
            cancelAll()
            notify(force: true)
        }
        return epoch
    }

    @discardableResult
    func remove() -> Int {
        let epoch = cancel()
        queue.addOperation { [self] in
            plan = nil
            done = [:]
            complete = []
            state = .idle
            try? FileManager.default.removeItem(at: Self.directory)
            notify(force: true)
        }
        return epoch
    }

    // MARK: - 会话回调

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription else { return }
        inflight[key] = totalBytesWritten
        notify()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let key = downloadTask.taskDescription, let located = locate(key) else { return }
        let (file, index) = located
        inflight.removeValue(forKey: key)
        guard !complete.contains(file.name), done[file.name]?.contains(index) != true else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 206,
              let data = try? Data(contentsOf: location, options: .mappedIfSafe),
              Int64(data.count) == length(file, index) else {
            retry(key, file: file, index: index, session: session)
            return
        }
        do {
            let handle = try FileHandle(forWritingTo: partURL(file))
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(Int64(index) * Self.chunk))
            try handle.write(contentsOf: data)
        } catch {
            retry(key, file: file, index: index, session: session)
            return
        }
        done[file.name, default: []].insert(index)
        saveParts(file)
        retries.removeValue(forKey: key)
        if done[file.name]?.count == chunks(file) { finalize(file) }
        finishIfComplete()
        notify(force: true)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let key = task.taskDescription else { return }
        inflight.removeValue(forKey: key)
        if cancelled.remove("\(key)|\(task.taskIdentifier)") != nil { return }
        guard let located = locate(key) else { return }
        let (file, index) = located
        guard !complete.contains(file.name), done[file.name]?.contains(index) != true else { return }
        if case .failed = state { return }
        // 被系统或用户强退后重新启动：任务带着续传数据报错，接着下
        if state == .idle { state = .running }
        if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            let resumed = session.downloadTask(withResumeData: data)
            resumed.taskDescription = key
            resumed.resume()
        } else {
            retry(key, file: file, index: index, session: session)
        }
        notify(force: true)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier,
              let handler = lock.withLock({ handlers.removeValue(forKey: identifier) }) else { return }
        nonisolated(unsafe) let completion = handler
        DispatchQueue.main.async { completion() }
    }

    // MARK: - 内部（只在 queue 上调用）

    private func bump() -> Int {
        lock.withLock {
            epoch += 1
            return epoch
        }
    }

    /// 按磁盘上的 .part / .parts 恢复每个文件的进度，缺失或大小不符的 .part 重新预留
    private func load(_ plan: Plan) {
        let manager = FileManager.default
        done = [:]
        complete = []
        for file in plan.manifest.files {
            let part = partURL(file)
            if !manager.fileExists(atPath: part.path), Self.size(of: url(file)) == file.size {
                complete.insert(file.name)
                continue
            }
            var finished: Set<Int> = []
            if Self.size(of: part) == file.size,
               let data = try? Data(contentsOf: partsURL(file)),
               let parts = try? JSONDecoder().decode(Parts.self, from: data), parts.chunk == Self.chunk {
                finished = parts.done
            } else {
                try? manager.removeItem(at: part)
                try? manager.removeItem(at: partsURL(file))
                if manager.createFile(atPath: part.path, contents: nil), let handle = try? FileHandle(forWritingTo: part) {
                    try? handle.truncate(atOffset: UInt64(file.size))
                    try? handle.close()
                }
            }
            done[file.name] = finished
        }
    }

    private func enqueue(_ key: String, file: File, index: Int, session: URLSession, delay: TimeInterval = 0) {
        guard let plan else { return }
        let start = Int64(index) * Self.chunk
        var request = URLRequest(url: plan.base.appendingPathComponent(file.name))
        request.setValue("bytes=\(start)-\(start + length(file, index) - 1)", forHTTPHeaderField: "Range")
        let task = session.downloadTask(with: request)
        task.taskDescription = key
        if delay > 0 { task.earliestBeginDate = Date().addingTimeInterval(delay) }
        task.resume()
    }

    private func retry(_ key: String, file: File, index: Int, session: URLSession) {
        let count = retries[key, default: 0] + 1
        retries[key] = count
        guard count <= 5 else {
            fail("网络不稳定，下载中断")
            return
        }
        enqueue(key, file: file, index: index, session: session, delay: Double(count * 3))
    }

    private func finalize(_ file: File) {
        let manager = FileManager.default
        let part = partURL(file)
        guard Self.sha256(part) == file.sha256 else {
            try? manager.removeItem(at: part)
            try? manager.removeItem(at: partsURL(file))
            done[file.name] = []
            fail("\(file.name) 校验失败，请重试")
            return
        }
        let target = url(file)
        try? manager.removeItem(at: target)
        do {
            try manager.moveItem(at: part, to: target)
        } catch {
            fail("无法写入语音包")
            return
        }
        try? manager.removeItem(at: partsURL(file))
        done.removeValue(forKey: file.name)
        complete.insert(file.name)
    }

    private func finishIfComplete() {
        guard let plan, state == .running, plan.manifest.files.allSatisfy({ complete.contains($0.name) }) else { return }
        do {
            try Data(plan.manifest.version.utf8).write(to: Self.marker)
            state = .done
        } catch {
            fail("无法写入语音包")
        }
    }

    private func fail(_ message: String) {
        state = .failed(message)
        inflight = [:]
        cancelAll()
        notify(force: true)
    }

    private func cancelAll() {
        allTasks { [self] tasks in
            for task in tasks {
                cancelled.insert("\(task.taskDescription ?? "")|\(task.taskIdentifier)")
                task.cancel()
            }
        }
    }

    /// 汇总所有会话的任务，回到 queue 上回调
    private func allTasks(_ completion: @escaping @Sendable ([URLSessionTask]) -> Void) {
        let sessions = lock.withLock { self.sessions }
        let queue = queue
        Task {
            var tasks: [URLSessionTask] = []
            for session in sessions { tasks += await session.allTasks }
            let found = tasks
            queue.addOperation { completion(found) }
        }
    }

    private func notify(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastNotify) > 0.25 else { return }
        lastNotify = now
        let files = plan?.manifest.files ?? []
        var received = inflight.values.reduce(0, +)
        for file in files {
            received += complete.contains(file.name) ? file.size : (done[file.name] ?? []).reduce(0) { $0 + length(file, $1) }
        }
        let total = files.reduce(0) { $0 + $1.size }
        let (observer, epoch) = lock.withLock { (self.observer, self.epoch) }
        observer?(Snapshot(epoch: epoch, received: min(received, total), total: total, state: state))
    }

    private func saveParts(_ file: File) {
        let parts = Parts(chunk: Self.chunk, done: done[file.name] ?? [])
        try? JSONEncoder().encode(parts).write(to: partsURL(file))
    }

    private func locate(_ key: String) -> (File, Int)? {
        guard let split = key.lastIndex(of: "#"), let index = Int(key[key.index(after: split)...]),
              let file = plan?.manifest.files.first(where: { $0.name == key[..<split] }) else { return nil }
        return (file, index)
    }

    private func chunks(_ file: File) -> Int { Int((file.size + Self.chunk - 1) / Self.chunk) }

    private func length(_ file: File, _ index: Int) -> Int64 { min(Self.chunk, file.size - Int64(index) * Self.chunk) }

    private func url(_ file: File) -> URL { Self.directory.appendingPathComponent(file.name) }

    private func partURL(_ file: File) -> URL { url(file).appendingPathExtension("part") }

    private func partsURL(_ file: File) -> URL { url(file).appendingPathExtension("parts") }

    private static func size(of url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    private static func sha256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
