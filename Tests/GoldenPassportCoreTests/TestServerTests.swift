import Foundation
import Testing
@testable import GoldenPassportCore

@Suite(.serialized)
struct TestServerTests {
    /// A taken port must not hang the run: waiting only for `.running` never returned when the
    /// random port was in use (seen once on 2026-11-21, the whole suite stalled).
    @Test func startRetriesWhenThePortIsTaken() async throws {
        let (first, takenPort) = try await startLocalHTTPServer { _ in .text("first") }
        defer { first.stop() }

        let start = Date()
        let (second, port) = try await startLocalHTTPServer(candidates: [takenPort]) { _ in .text("second") }
        defer { second.stop() }

        #expect(port != takenPort)
        #expect(Date().timeIntervalSince(start) < 10)
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!)
        #expect(String(data: data, encoding: .utf8) == "second")
    }
}
