import Foundation
import Network

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]

    public init(method: String, path: String, headers: [String: String] = [:]) {
        self.method = method
        self.path = path
        self.headers = headers
    }

    /// Parses the request line and headers; returns nil until the header block is complete.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers)
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public var status: Int
    public var contentType: String
    public var body: String

    public static func text(_ body: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: body)
    }

    public static func html(_ body: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/html; charset=utf-8", body: body)
    }

    func serialized() -> Data {
        let reasons = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed"]
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(bodyData.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
        return Data(head.utf8) + bodyData
    }
}

/// Routes of the local verification-code API:
///   GET /             HTML list of all codes
///   GET /code/<name>  plain-text code of one account
public enum CodeAPI {
    public static func handle(_ request: HTTPRequest, store: AccountStore, now: Date = Date()) -> HTTPResponse {
        // Reject other Host headers to block DNS-rebinding pages from reading codes.
        let host = request.headers["host"].map(hostWithoutPort) ?? ""
        guard ["localhost", "127.0.0.1", "[::1]"].contains(host.lowercased()) else {
            return .text("forbidden", status: 403)
        }
        guard request.method == "GET" else {
            return .text("method not allowed", status: 405)
        }

        let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        if path == "/" {
            return .html(indexPage(store.codes(at: now)))
        }
        if path.hasPrefix("/code/") {
            let encoded = String(path.dropFirst("/code/".count))
            let name = encoded.removingPercentEncoding ?? encoded
            guard let code = store.code(named: name, at: now) else {
                return .text("key does not exists!", status: 404)
            }
            switch code.result {
            case .success(let value): return .text(value)
            case .failure(let error): return .text(error.localizedDescription, status: 400)
            }
        }
        return .text("not found", status: 404)
    }

    private static func hostWithoutPort(_ host: String) -> String {
        if host.hasPrefix("[") {
            return host.firstIndex(of: "]").map { String(host[...$0]) } ?? host
        }
        return host.split(separator: ":").first.map(String.init) ?? host
    }

    private static func indexPage(_ codes: [AccountCode]) -> String {
        let items = codes.map { code -> String in
            let name = code.account.name
            let href = "/code/" + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? name)
            return "<li><a href=\"\(escape(href))\">\(escape(name)) -&gt; \(escape(code.displayCode))</a></li>"
        }.joined(separator: "\n")
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>GoldenPassport</title></head>
        <body><h3>Verification code list:</h3>
        <ul>
        \(items)
        </ul></body></html>
        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Minimal HTTP/1.1 server bound to 127.0.0.1 only.
public final class LocalHTTPServer: @unchecked Sendable {
    public enum State: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    public let port: UInt16
    public var onStateChange: ((State) -> Void)?
    public private(set) var state: State = .stopped

    private let handler: @Sendable (HTTPRequest) -> HTTPResponse
    private let queue = DispatchQueue(label: "GoldenPassport.http")
    private var listener: NWListener?

    public init(port: UInt16, handler: @escaping @Sendable (HTTPRequest) -> HTTPResponse) {
        self.port = port
        self.handler = handler
    }

    public func start() {
        guard listener == nil, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.setState(.running)
                case .failed(let error):
                    self.listener?.cancel()
                    self.listener = nil
                    self.setState(.failed(error.localizedDescription))
                case .cancelled:
                    if case .failed = self.state { return }
                    self.setState(.stopped)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            self.listener = listener
            setState(.starting)
            listener.start(queue: queue)
        } catch {
            setState(.failed(error.localizedDescription))
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        setState(.stopped)
    }

    private func setState(_ newState: State) {
        DispatchQueue.main.async {
            self.state = newState
            self.onStateChange?(newState)
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let request = HTTPRequest.parse(buffer) {
                self.respond(self.handler(request), on: connection)
            } else if error != nil || isComplete || buffer.count > 64 * 1024 {
                self.respond(.text("bad request", status: 400), on: connection)
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
