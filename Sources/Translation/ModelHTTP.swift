import Foundation

struct ModelConfiguration: Sendable {
    let endpoint: URL
    let model: String
    var isLocal: Bool { ["localhost", "127.0.0.1", "[::1]", "::1"].contains(endpoint.host?.lowercased() ?? "") }

    init(endpoint: String, model: String) throws {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.path.hasSuffix("/chat/completions") else { throw ModelError.configuration }
        let local = ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased())
        guard url.scheme == "https" || (url.scheme == "http" && local) else { throw ModelError.configuration }
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ModelError.configuration }
        self.endpoint = url; self.model = name
    }
}

enum ModelError: LocalizedError {
    case configuration, missingKey, http(Int), invalidResponse, tooLarge
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .configuration: return L("请填写完整的 HTTPS chat/completions 接口地址和模型名；仅本机服务允许 HTTP。")
        case .missingKey: return L("尚未保存此接口的 API Key。")
        case .http(let code): return L("翻译服务返回 HTTP %ld。", code)
        case .invalidResponse: return L("翻译服务没有返回完整、有效的文字。")
        case .tooLarge: return L("翻译请求或响应超过长度限制。")
        }
    }
}

// Never forward speech text or Authorization to a redirected destination.
private final class NoModelRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct ModelHTTP {
    static func chatRequest(configuration: ModelConfiguration, apiKey: String,
                            system: String, user: String, timeout: TimeInterval = 8) throws -> URLRequest {
        guard system.utf8.count + user.utf8.count <= 128_000 else { throw ModelError.tooLarge }
        guard configuration.isLocal || !apiKey.isEmpty else { throw ModelError.missingKey }
        let body: [String: Any] = ["model": configuration.model, "stream": false,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
        var request = URLRequest(url: configuration.endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// `allowCut`: also the text of an answer that ran into the model's length limit. A proofread
    /// that stops in the middle is useless; of a long structured answer the complete part is not.
    static func decode(_ data: Data, status: Int, allowCut: Bool = false) throws -> String {
        guard (200..<300).contains(status) else { throw ModelError.http(status) }
        guard data.count <= 128_000 else { throw ModelError.tooLarge }
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String?; let refusal: String? }
                let message: Message
                let finish_reason: String?
            }
            let choices: [Choice]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let choice = response.choices.first,
              allowCut || choice.finish_reason == nil || choice.finish_reason == "stop",
              choice.message.refusal == nil,
              let text = choice.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { throw ModelError.invalidResponse }
        return text
    }

    /// The model's answer to one system and one user message. `timeout`: seconds for the whole exchange.
    static func chat(configuration: ModelConfiguration, apiKey: String,
                     system: String, user: String, timeout: TimeInterval) async throws -> String {
        let request = try chatRequest(configuration: configuration, apiKey: apiKey, system: system, user: user, timeout: timeout)
        let (data, status) = try await send(request, timeout: timeout)
        return try decode(data, status: status, allowCut: true)
    }

    private static func send(_ request: URLRequest, timeout: TimeInterval) async throws -> (Data, Int) {
        let options = URLSessionConfiguration.ephemeral
        options.timeoutIntervalForRequest = timeout; options.timeoutIntervalForResource = timeout
        options.httpCookieStorage = nil; options.urlCache = nil; options.httpShouldSetCookies = false
        let session = URLSession(configuration: options, delegate: NoModelRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ModelError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ModelError.http(http.statusCode) }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 128_000 else { throw ModelError.tooLarge }
            data.append(byte)
        }
        return (data, http.statusCode)
    }
}
