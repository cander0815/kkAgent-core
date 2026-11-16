// 和核心通信：只走本机 HTTP 接口，界面不直接碰数据库和会话文件
import Foundation

enum ClientError: LocalizedError {
    case server(String) // 核心返回的错误（中文）
    case offline        // 连不上核心

    var errorDescription: String? {
        switch self {
        case .server(let message): return message
        case .offline: return "连不上 kkAgent 核心"
        }
    }
}

struct APIClient {
    let port = Int(ProcessInfo.processInfo.environment["KKAGENT_PORT"] ?? "") ?? 7788

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:] // 连本机，不走系统代理
        config.timeoutIntervalForRequest = 5
        return URLSession(configuration: config)
    }()

    func get<T: Decodable>(_ path: String) async throws -> T {
        try await request("GET", path, body: Optional<String>.none)
    }

    func post<T: Decodable, B: Encodable>(_ path: String, _ body: B) async throws -> T {
        try await request("POST", path, body: body)
    }

    func delete(_ path: String) async throws {
        let _: OkResult = try await request("DELETE", path, body: Optional<String>.none)
    }

    private func request<T: Decodable, B: Encodable>(_ method: String, _ path: String, body: B?) async throws -> T {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw ClientError.offline
        }
        if (response as? HTTPURLResponse)?.statusCode != 200 {
            let message = (try? JSONDecoder().decode(APIError.self, from: data))?.error ?? "请求失败"
            throw ClientError.server(message)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
