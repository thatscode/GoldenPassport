import Foundation
import Testing
@testable import GoldenPassportCore

struct CodeAPITests {
    let date = Date(timeIntervalSince1970: 1111111109)
    let expected = TOTP(secret: Data("foobar".utf8)).code(at: Date(timeIntervalSince1970: 1111111109))

    func store() throws -> AccountStore {
        let store = AccountStore(directory: try makeTempDirectory())
        try store.add(name: "AWS:alice@123", url: validURL)
        try store.add(name: "<b>", url: validURL)
        return store
    }

    func get(_ path: String, host: String = "localhost:17304") -> HTTPRequest {
        HTTPRequest(method: "GET", path: path, headers: ["host": host])
    }

    @Test func codeByEncodedName() throws {
        let response = CodeAPI.handle(get("/code/AWS:alice%40123"), store: try store(), now: date)
        #expect(response == .text(expected))
        #expect(CodeAPI.handle(get("/code/AWS:alice@123"), store: try store(), now: date) == .text(expected))
    }

    @Test func missingIs404() throws {
        #expect(CodeAPI.handle(get("/code/nope"), store: try store(), now: date).status == 404)
        #expect(CodeAPI.handle(get("/other"), store: try store(), now: date).status == 404)
    }

    @Test func indexIsUTF8AndEscaped() throws {
        let response = CodeAPI.handle(get("/"), store: try store(), now: date)
        #expect(response.contentType == "text/html; charset=utf-8")
        #expect(response.body.contains("<meta charset=\"utf-8\">"))
        #expect(response.body.contains("&lt;b&gt; -&gt; \(expected)"))
        #expect(!response.body.contains("<b>"))
    }

    @Test(arguments: ["localhost", "127.0.0.1:8080", "[::1]:17304", "LOCALHOST:1"])
    func allowsLoopbackHosts(host: String) throws {
        #expect(CodeAPI.handle(get("/", host: host), store: try store(), now: date).status == 200)
    }

    @Test(arguments: ["evil.example.com", "evil.example.com:17304", ""])
    func rejectsForeignHosts(host: String) throws {
        #expect(CodeAPI.handle(get("/", host: host), store: try store(), now: date).status == 403)
    }

    @Test func parsesRawRequest() {
        let raw = Data("GET /code/a%20b HTTP/1.1\r\nHost: localhost:1\r\nUser-Agent: curl\r\n\r\n".utf8)
        let request = HTTPRequest.parse(raw)
        #expect(request?.path == "/code/a%20b")
        #expect(request?.headers["host"] == "localhost:1")
        #expect(HTTPRequest.parse(Data("GET / HTTP/1.1\r\n".utf8)) == nil)
    }
}

@Suite(.serialized)
struct LocalHTTPServerTests {
    @Test func servesOverLoopback() async throws {
        let port = UInt16.random(in: 40000...60000)
        let server = LocalHTTPServer(port: port) { _ in .text("hello") }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            server.onStateChange = { state in
                if state == .running { continuation.resume() }
            }
            server.start()
        }
        defer { server.stop() }

        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!)
        #expect(String(data: data, encoding: .utf8) == "hello")
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }
}
