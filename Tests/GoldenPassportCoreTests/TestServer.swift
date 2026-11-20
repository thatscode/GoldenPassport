import Foundation
@testable import GoldenPassportCore

struct TestServerUnavailable: Error {}

/// Starts a LocalHTTPServer on loopback, trying `candidates` first and then random ports. A random
/// port can already be taken: then the server reports `.failed`, and a test that waits only for
/// `.running` would hang the whole run.
func startLocalHTTPServer(candidates: [UInt16] = [],
                          handler: @escaping @Sendable (HTTPRequest) -> HTTPResponse) async throws -> (LocalHTTPServer, UInt16) {
    let ports = candidates + (0..<5).map { _ in UInt16.random(in: 40000...60000) }
    for port in ports {
        let server = LocalHTTPServer(port: port, handler: handler)
        let started = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce()
            server.onStateChange = { state in
                switch state {
                case .running: if once.claim() { continuation.resume(returning: true) }
                case .failed: if once.claim() { continuation.resume(returning: false) }
                case .stopped, .starting: break
                }
            }
            server.start()
        }
        if started { return (server, port) }
        server.stop()
    }
    throw TestServerUnavailable()
}

/// The server can report several states; the continuation must be resumed once.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
