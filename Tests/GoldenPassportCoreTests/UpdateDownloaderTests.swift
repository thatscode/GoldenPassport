import Foundation
import Testing
@testable import GoldenPassportCore

/// Serves each URL from a script registered for it: a status, then chunks at intervals. Tests run in
/// parallel, so every test uses its own URL.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Script {
        var status = 200
        var contentLength: Int?
        var chunks: [Data] = []
        var interval: TimeInterval = 0
        /// Keep sending one byte per interval until stopped.
        var endless = false
        /// Send the headers, then nothing.
        var stall = false
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var scripts: [URL: Script] = [:]
    nonisolated(unsafe) private static var requests: [URL: URLRequest] = [:]

    static func register(_ script: Script, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        scripts[url] = script
    }

    static func request(for url: URL) -> URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return requests[url]
    }

    /// Client callbacks must come from the thread that called startLoading, or URLSession holds the
    /// data back until the load finishes: chunks are sent from timers on that thread's run loop.
    private var timer: Timer?
    private var sent = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        let script = Self.scripts[url] ?? Script(status: 404)
        Self.requests[url] = request
        Self.lock.unlock()

        var headers = ["Content-Type": "application/zip"]
        if let length = script.contentLength { headers["Content-Length"] = String(length) }
        let response = HTTPURLResponse(url: url, statusCode: script.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if script.stall { return }
        let timer = Timer(timeInterval: max(script.interval, 0.001), repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            if script.endless {
                self.client?.urlProtocol(self, didLoad: Data("x".utf8))
            } else if self.sent < script.chunks.count {
                self.client?.urlProtocol(self, didLoad: script.chunks[self.sent])
                self.sent += 1
            } else {
                timer.invalidate()
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
        self.timer = timer
        RunLoop.current.add(timer, forMode: .common)
    }

    override func stopLoading() {
        timer?.invalidate()
        timer = nil
    }
}

struct UpdateDownloaderTests {
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return configuration
    }

    static func url() -> URL { URL(string: "https://download.example/\(UUID().uuidString)/gp.zip")! }

    static func downloader(idle: TimeInterval = 60, total: TimeInterval = 600) -> UpdateDownloader {
        UpdateDownloader(appVersion: "0.2.3", configuration: configuration(), idleTimeout: idle, totalTimeout: total)
    }

    final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(Int64, Int64?)] = []
        func append(_ received: Int64, _ expected: Int64?) { lock.lock(); entries.append((received, expected)); lock.unlock() }
        var all: [(Int64, Int64?)] { lock.lock(); defer { lock.unlock() }; return entries }
    }

    @Test func downloadsWithProgressAndIdentity() async throws {
        let url = Self.url()
        let chunks = [Data(repeating: 0x61, count: 10), Data(repeating: 0x62, count: 10), Data(repeating: 0x63, count: 10)]
        StubProtocol.register(.init(contentLength: 30, chunks: chunks, interval: 0.05), for: url)
        let directory = try makeTempDirectory()
        let log = ProgressLog()

        let file = try await Self.downloader().download(UpdatePackage(url: url, size: 30, sha256: nil), into: directory) { log.append($0, $1) }

        #expect(file.path == directory.appendingPathComponent("package.zip").path)
        #expect(try Data(contentsOf: file) == chunks.reduce(Data(), +))
        #expect(log.all.count >= 3)
        #expect(log.all.last.map { $0.0 } == 30)
        #expect(log.all.last.flatMap { $0.1 } == 30)
        let request = try #require(StubProtocol.request(for: url))
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "GoldenPassport/0.2.3")
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en")
    }

    @Test func httpErrorsFail() async throws {
        let url = Self.url()
        StubProtocol.register(.init(status: 404, chunks: [Data("Not Found".utf8)]), for: url)
        let directory = try makeTempDirectory()
        await expectUpdateError("download") {
            _ = try await Self.downloader().download(UpdatePackage(url: url, size: nil, sha256: nil), into: directory) { _, _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("package.zip").path))
    }

    @Test func stalledDownloadFailsAfterIdleTimeout() async throws {
        let url = Self.url()
        StubProtocol.register(.init(contentLength: 30, stall: true), for: url)
        let start = Date()
        await expectUpdateError("download") {
            _ = try await Self.downloader(idle: 0.3).download(UpdatePackage(url: url, size: 30, sha256: nil),
                                                             into: try makeTempDirectory()) { _, _ in }
        }
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func slowButSteadyDownloadsAreNotCutOff() async throws {
        let url = Self.url()
        let chunks = (0..<5).map { _ in Data("x".utf8) }
        StubProtocol.register(.init(contentLength: 5, chunks: chunks, interval: 0.2), for: url)
        let file = try await Self.downloader(idle: 0.5).download(UpdatePackage(url: url, size: 5, sha256: nil),
                                                                 into: try makeTempDirectory()) { _, _ in }
        #expect(try Data(contentsOf: file).count == 5)
    }

    @Test func totalTimeoutStopsEndlessDownloads() async throws {
        let url = Self.url()
        StubProtocol.register(.init(interval: 0.05, endless: true), for: url)
        let start = Date()
        await expectUpdateError("download") {
            _ = try await Self.downloader(idle: 5, total: 0.5).download(UpdatePackage(url: url, size: nil, sha256: nil),
                                                                       into: try makeTempDirectory()) { _, _ in }
        }
        #expect(Date().timeIntervalSince(start) < 2.5)
    }

    @Test func cancellingStopsAndRemovesThePartialFile() async throws {
        let url = Self.url()
        StubProtocol.register(.init(interval: 0.05, endless: true), for: url)
        let directory = try makeTempDirectory()
        let downloader = Self.downloader()
        let task = Task {
            try await downloader.download(UpdatePackage(url: url, size: nil, sha256: nil), into: directory) { _, _ in }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("package.zip").path))
    }

    @Test func prepareDirectoryClearsLeftovers() throws {
        let caches = try makeTempDirectory()
        let updates = UpdateDownloader.updatesDirectory(bundleIdentifier: "com.example", cachesDirectory: caches)
        #expect(updates.path == caches.appendingPathComponent("com.example/Updates").path)
        let old = updates.appendingPathComponent("0.2.2", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old.appendingPathComponent("package.zip"))

        let fresh = try UpdateDownloader.prepareDirectory(bundleIdentifier: "com.example", version: "0.2.4", cachesDirectory: caches)

        #expect(fresh.path == updates.appendingPathComponent("0.2.4").path)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        let permissions = try FileManager.default.attributesOfItem(atPath: fresh.path)[.posixPermissions] as? Int
        #expect(permissions == 0o700)
        UpdateDownloader.clearCache(bundleIdentifier: "com.example", cachesDirectory: caches)
        #expect(!FileManager.default.fileExists(atPath: updates.path))
    }
}
