// 极简 HTTP/1.1 服务：只监听 127.0.0.1，一个请求一个连接，处理完就关。
// 只服务本机的界面和 kkAgent 命令行，不需要 keep-alive、分块传输这些。
import Foundation
import Network

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String] // 头名统一小写
    let body: Data

    var isForm: Bool { headers["content-type"]?.contains("application/x-www-form-urlencoded") == true }

    /// 缓冲区里还不是一个完整请求时返回 nil，继续收
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = max(0, Int(headers["content-length"] ?? "0") ?? 0) // 负数会让下面的 prefix 崩溃
        let body = data[headerEnd.upperBound...]
        guard body.count >= length else { return nil }

        let components = URLComponents(string: String(requestLine[1]))
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return HTTPRequest(method: String(requestLine[0]), path: components?.path ?? "/", query: query,
                           headers: headers, body: Data(body.prefix(length)))
    }

    /// 表单请求体（kkAgent 命令行用 curl --data-urlencode 提交）
    func formValues() -> [String: String] {
        var values: [String: String] = [:]
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            // 表单编码里空格是 +，其余是 %XX
            let decode = { (s: Substring) in s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(s) }
            values[decode(parts[0])] = parts.count > 1 ? decode(parts[1]) : ""
        }
        return values
    }
}

struct HTTPResponse {
    var status: Int
    var contentType: String
    var body: Data

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    static func text(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data((text + "\n").utf8))
    }

    func serialize() -> Data {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 500: "Internal Server Error"][status] ?? "OK"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

final class HTTPServer {
    private let listener: NWListener
    private let handler: (HTTPRequest) -> HTTPResponse
    private let queue = DispatchQueue(label: "kkagent.http", attributes: .concurrent)

    init(port: Int, handler: @escaping (HTTPRequest) -> HTTPResponse) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // 只绑本机回环地址，局域网里的其他机器访问不到
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(integerLiteral: UInt16(port)))
        listener = try NWListener(using: parameters)
        self.handler = handler
    }

    func start(onReady: @escaping () -> Void, onFailure: @escaping (Error) -> Void) {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: onReady()
            case .failed(let error): onFailure(error)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = HTTPRequest.parse(buffer) {
                let response = self.handler(request)
                connection.send(content: response.serialize(), completion: .contentProcessed { _ in connection.cancel() })
            } else if isComplete || error != nil || buffer.count > 8 << 20 { // 超过 8MB 还没收完，不是正常请求
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }
}
