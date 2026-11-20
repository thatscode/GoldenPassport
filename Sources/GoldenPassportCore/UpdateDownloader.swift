import Foundation

/// Downloads the release zip with progress (docs/design/in-app-update.md, 5.2). Its own watchdog
/// fails a download that receives nothing for `idleTimeout` or runs past `totalTimeout`, rather than
/// relying on URLSession's timeouts. A data task, not a download task: it reports every chunk as it
/// arrives, so a slow but steady connection is never taken for a stalled one (download tasks report
/// progress in batches). One download at a time per instance.
public final class UpdateDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let appVersion: String
    private let configuration: URLSessionConfiguration
    private let idleTimeout: TimeInterval
    private let totalTimeout: TimeInterval

    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var watchdog: DispatchSourceTimer?
    private var destination: URL?
    private var progress: (@Sendable (Int64, Int64?) -> Void)?
    private var started = Date()
    private var lastActivity = Date()
    private var cancelled = false
    /// Touched only on the session's serial delegate queue.
    private var file: FileHandle?
    private var received: Int64 = 0
    private var expected: Int64?

    /// `.ephemeral` keeps no cookies, cache or credentials and follows the system proxy settings.
    public init(appVersion: String, configuration: URLSessionConfiguration = .ephemeral,
                idleTimeout: TimeInterval = 60, totalTimeout: TimeInterval = 600) {
        self.appVersion = appVersion
        self.configuration = configuration
        self.idleTimeout = idleTimeout
        self.totalTimeout = totalTimeout
    }

    // MARK: Cache directory

    /// `~/Library/Caches/<bundle id>/Updates`.
    public static func updatesDirectory(bundleIdentifier: String, cachesDirectory: URL? = nil) -> URL {
        let caches = cachesDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent(bundleIdentifier, isDirectory: true).appendingPathComponent("Updates", isDirectory: true)
    }

    /// Clears whatever an earlier attempt left and returns a fresh, owner-only `Updates/<version>`.
    public static func prepareDirectory(bundleIdentifier: String, version: String, cachesDirectory: URL? = nil) throws -> URL {
        let fm = FileManager.default
        let updates = updatesDirectory(bundleIdentifier: bundleIdentifier, cachesDirectory: cachesDirectory)
        if fm.fileExists(atPath: updates.path) { try fm.removeItem(at: updates) }
        let safeVersion = version.replacingOccurrences(of: "/", with: "_")
        let directory = updates.appendingPathComponent(safeVersion, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: updates.path)
        return directory
    }

    public static func clearCache(bundleIdentifier: String, cachesDirectory: URL? = nil) {
        try? FileManager.default.removeItem(at: updatesDirectory(bundleIdentifier: bundleIdentifier, cachesDirectory: cachesDirectory))
    }

    // MARK: Download

    /// Downloads to `directory/package.zip`. Cancelling the calling task stops the download, removes
    /// the partial file and throws `CancellationError`.
    public func download(_ package: UpdatePackage, into directory: URL,
                         progress: @escaping @Sendable (_ received: Int64, _ expected: Int64?) -> Void) async throws -> URL {
        let destination = directory.appendingPathComponent("package.zip")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                start(package.url, destination: destination, progress: progress, continuation: continuation)
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    private func start(_ url: URL, destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void,
                       continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        self.destination = destination
        self.progress = progress
        started = Date()
        lastActivity = started

        let configuration = self.configuration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = idleTimeout
        configuration.timeoutIntervalForResource = totalTimeout
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        let interval = max(0.05, min(idleTimeout, totalTimeout) / 5)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.checkTimeouts() }
        watchdog = timer
        lock.unlock()

        var request = URLRequest(url: url)
        request.setValue("GoldenPassport/\(appVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        session.dataTask(with: request).resume()
        timer.resume()
    }

    private func checkTimeouts() {
        lock.lock()
        let now = Date()
        let idle = now.timeIntervalSince(lastActivity) > idleTimeout
        let total = now.timeIntervalSince(started) > totalTimeout
        lock.unlock()
        if idle {
            finish(.failure(UpdateError.download(String(localized: "连续 \(Int(idleTimeout.rounded(.up))) 秒没有收到数据"))))
        } else if total {
            finish(.failure(UpdateError.download(String(localized: "\(Int(totalTimeout.rounded(.up))) 秒内没有下载完"))))
        }
    }

    /// Completes the download once; later calls do nothing.
    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        if case .failure(let error) = result, error is CancellationError { cancelled = true }
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let session = self.session, watchdog = self.watchdog, destination = self.destination
        self.session = nil
        self.watchdog = nil
        lock.unlock()

        watchdog?.cancel()
        session?.invalidateAndCancel()
        if case .failure = result, let destination {
            try? FileManager.default.removeItem(at: destination)
        }
        continuation.resume(with: result)
    }

    // MARK: URLSessionDataDelegate

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            completionHandler(.cancel)
            finish(.failure(UpdateError.download("HTTP \(status)")))
            return
        }
        lock.lock()
        let destination = self.destination
        lock.unlock()
        guard let destination, FileManager.default.createFile(atPath: destination.path, contents: nil,
                                                               attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: destination) else {
            completionHandler(.cancel)
            finish(.failure(UpdateError.download(String(localized: "无法写入下载的文件"))))
            return
        }
        file = handle
        received = 0
        expected = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let file else { return }
        do {
            try file.write(contentsOf: data)
        } catch {
            finish(.failure(UpdateError.download(error.localizedDescription)))
            return
        }
        received += Int64(data.count)
        lock.lock()
        lastActivity = Date()
        let progress = self.progress
        lock.unlock()
        progress?(received, expected)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? file?.close()
        file = nil
        lock.lock()
        let destination = self.destination
        lock.unlock()
        if let error {
            finish(.failure(UpdateError.download(error.localizedDescription)))
        } else if let destination {
            finish(.success(destination))
        }
    }
}
