import Foundation

struct AIModel: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let contextWindow: Int?
    let provider: String

    var providerName: String {
        if let slash = id.firstIndex(of: "/") {
            return String(id[..<slash])
        }
        return provider.isEmpty ? "其他" : provider
    }
}

private struct ModelsEnvelope: Decodable {
    struct Entry: Decodable {
        let id: String
        let displayName: String?
        let contextWindow: Int?
        let ownedBy: String?

        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
            case name
            case contextWindow = "context_window"
            case ownedBy = "owned_by"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            displayName = (try? c.decodeIfPresent(String.self, forKey: .displayName))
                ?? (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
            contextWindow = (try? c.decodeIfPresent(Int.self, forKey: .contextWindow)) ?? nil
            ownedBy = (try? c.decodeIfPresent(String.self, forKey: .ownedBy)) ?? nil
        }
    }

    let data: [Entry]
}

struct AIClient: Sendable {
    enum ClientError: LocalizedError {
        case badURL(String)
        case http(Int, String)
        case emptyResponse
        case malformedPayload

        var errorDescription: String? {
            switch self {
            case .badURL(let value): "AI 地址不合法：\(value)"
            case .http(let code, let body): "网关返回 HTTP \(code)：\(body.prefix(160))"
            case .emptyResponse: "模型返回了空内容"
            case .malformedPayload: "无法解析网关返回的数据"
            }
        }
    }

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 90
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    func fetchModels(baseURL: String, apiKey: String) async throws -> [AIModel] {
        let url = try endpoint(baseURL, path: "models")
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        applyAuth(&request, apiKey: apiKey)
        let (data, response) = try await session.data(for: request)
        try check(response, data: data)

        let envelope: ModelsEnvelope
        do {
            envelope = try JSONDecoder().decode(ModelsEnvelope.self, from: data)
        } catch {
            throw ClientError.malformedPayload
        }

        return envelope.data
            .map { entry in
                AIModel(
                    id: entry.id,
                    displayName: entry.displayName ?? entry.id,
                    contextWindow: entry.contextWindow,
                    provider: entry.ownedBy ?? ""
                )
            }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    func chat(
        baseURL: String,
        apiKey: String,
        model: String,
        system: String,
        user: String,
        temperature: Double = 0.2,
        timeout: Double
    ) async throws -> String {
        let url = try endpoint(baseURL, path: "chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request, apiKey: apiKey)

        let payload: [String: Any] = [
            "model": model,
            "temperature": temperature,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        try check(response, data: data)

        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any]
        else {
            throw ClientError.malformedPayload
        }

        if let text = message["content"] as? String, !text.isEmpty {
            return text
        }
        if let parts = message["content"] as? [[String: Any]] {
            let joined = parts.compactMap { $0["text"] as? String }.joined()
            if !joined.isEmpty { return joined }
        }
        throw ClientError.emptyResponse
    }

    private func endpoint(_ base: String, path: String) throws -> URL {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed + "/" + path), url.scheme != nil else {
            throw ClientError.badURL(base)
        }
        return url
    }

    private func applyAuth(_ request: inout URLRequest, apiKey: String) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }

    private func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.malformedPayload
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ClientError.http(http.statusCode, body)
        }
    }
}
