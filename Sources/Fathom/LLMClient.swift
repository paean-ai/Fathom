import Foundation

/// Minimal config for a DeepSeek-compatible (OpenAI-style) chat endpoint.
public struct LLMConfig: Sendable {
    public var apiKey: String
    public var model: String
    public var baseURL: URL
    public var temperature: Double

    public init(apiKey: String, model: String = "deepseek-chat",
                baseURL: URL = URL(string: "https://api.deepseek.com/v1")!,
                temperature: Double = 0.3) {
        self.apiKey = apiKey; self.model = model; self.baseURL = baseURL; self.temperature = temperature
    }
}

/// The orchestrator talks to the model through this protocol — so tests inject a
/// scripted mock and real apps inject `DeepSeekClient`.
public protocol LLMClient: Sendable {
    /// One completion. `tools` non-empty ⇒ the model may return tool calls.
    func complete(messages: [ChatMessage], tools: [[String: Any]]) async throws -> Completion
}

/// HTTP client for DeepSeek's chat-completions API (OpenAI-compatible).
public struct DeepSeekClient: LLMClient {
    public let config: LLMConfig
    private let session: URLSession
    public init(config: LLMConfig, session: URLSession = .shared) {
        self.config = config; self.session = session
    }

    public func complete(messages: [ChatMessage], tools: [[String: Any]]) async throws -> Completion {
        var body: [String: Any] = [
            "model": config.model,
            "temperature": config.temperature,
            "messages": messages.map(Self.wire),
        ]
        if !tools.isEmpty { body["tools"] = tools; body["tool_choice"] = "auto" }

        var req = URLRequest(url: config.baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: req)
        return try Self.parseCompletion(data)
    }

    /// Decode a chat-completions HTTP response body into a `Completion`. Public so
    /// host apps that own their own transport (auth, retry) can still reuse the SDK's
    /// wire format in one place.
    public static func parseCompletion(_ data: Data) throws -> Completion {
        let decoded = try JSONDecoder().decode(WireResponse.self, from: data)
        let msg = decoded.choices.first?.message
        let calls = (msg?.toolCalls ?? []).map { ToolCall(id: $0.id, name: $0.function.name, arguments: $0.function.arguments) }
        return Completion(content: msg?.content, toolCalls: calls)
    }

    /// Convert a ChatMessage to the wire JSON the API expects.
    public static func wire(_ m: ChatMessage) -> [String: Any] {
        var d: [String: Any] = ["role": m.role.rawValue, "content": m.content]
        if !m.toolCalls.isEmpty {
            d["tool_calls"] = m.toolCalls.map {
                ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]]
            }
        }
        if let tcid = m.toolCallID { d["tool_call_id"] = tcid }
        return d
    }

    // Decoding
    private struct WireResponse: Decodable {
        struct Choice: Decodable { let message: Msg }
        struct Msg: Decodable {
            let content: String?
            let toolCalls: [Call]?
            enum CodingKeys: String, CodingKey { case content, toolCalls = "tool_calls" }
        }
        struct Call: Decodable { let id: String; let function: Fn }
        struct Fn: Decodable { let name: String; let arguments: String }
        let choices: [Choice]
    }
}
