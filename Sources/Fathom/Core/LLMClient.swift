import Foundation

/// Minimal config for a DeepSeek-compatible (OpenAI-style) chat endpoint.
public struct LLMConfig: Sendable {
    public var apiKey: String
    public var model: String
    public var baseURL: URL
    public var temperature: Double
    /// THINKING MODE (deepseek-v4): the model reasons before answering — including between tool
    /// calls — and returns the chain of thought as `reasoning_content`. Off by default. When on,
    /// the API REQUIRES tool-call assistant turns to carry their `reasoning_content` back in every
    /// subsequent request (else 400) — `DeepSeekClient.wire` and the `Orchestrator` handle that.
    public var thinking: Bool
    /// Reasoning effort for thinking mode ("high" / "max"); nil sends no preference.
    public var reasoningEffort: String?

    public init(apiKey: String, model: String = "deepseek-v4-flash",
                baseURL: URL = URL(string: "https://api.deepseek.com/v1")!,
                temperature: Double = 0.3,
                thinking: Bool = false, reasoningEffort: String? = nil) {
        self.apiKey = apiKey; self.model = model; self.baseURL = baseURL; self.temperature = temperature
        self.thinking = thinking; self.reasoningEffort = reasoningEffort
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
        let body = requestBody(messages: messages, tools: tools)

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
        let usage = decoded.usage.map {
            Usage(prompt: $0.promptTokens ?? 0, completion: $0.completionTokens ?? 0, total: $0.totalTokens,
                  cacheHit: $0.cacheHitTokens ?? 0, cacheMiss: $0.cacheMissTokens ?? 0)
        }
        let reasoning = msg?.reasoningContent.flatMap { $0.isEmpty ? nil : $0 }
        return Completion(content: msg?.content, toolCalls: calls, usage: usage, reasoningContent: reasoning)
    }

    /// The chat-completions request body — one place for the wire contract, shared by
    /// `complete` and the streaming path. Internal → unit-testable.
    func requestBody(messages: [ChatMessage], tools: [[String: Any]], stream: Bool = false) -> [String: Any] {
        var body: [String: Any] = [
            "model": config.model,
            "temperature": config.temperature,
            "messages": messages.map(Self.wire),
        ]
        if !tools.isEmpty { body["tools"] = tools; body["tool_choice"] = "auto" }
        if config.thinking { body["thinking"] = ["type": "enabled"] }
        if let effort = config.reasoningEffort { body["reasoning_effort"] = effort }
        if stream { body["stream"] = true; body["stream_options"] = ["include_usage": true] }
        return body
    }

    /// Convert a ChatMessage to the wire JSON the API expects.
    public static func wire(_ m: ChatMessage) -> [String: Any] {
        var d: [String: Any] = ["role": m.role.rawValue, "content": m.content]
        if !m.toolCalls.isEmpty {
            d["tool_calls"] = m.toolCalls.map {
                ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]]
            }
            // Thinking mode: a tool-call turn must return its chain of thought to the API in
            // every subsequent request, or the API rejects the transcript with a 400. Non-tool
            // turns deliberately don't send it (the API ignores it at best).
            if let rc = m.reasoningContent, !rc.isEmpty { d["reasoning_content"] = rc }
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
            let reasoningContent: String?
            enum CodingKeys: String, CodingKey {
                case content, toolCalls = "tool_calls", reasoningContent = "reasoning_content"
            }
        }
        struct Call: Decodable { let id: String; let function: Fn }
        struct Fn: Decodable { let name: String; let arguments: String }
        struct UsageWire: Decodable {
            let promptTokens: Int?; let completionTokens: Int?; let totalTokens: Int?
            let cacheHitTokens: Int?; let cacheMissTokens: Int?
            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens", completionTokens = "completion_tokens", totalTokens = "total_tokens"
                case cacheHitTokens = "prompt_cache_hit_tokens", cacheMissTokens = "prompt_cache_miss_tokens"
            }
        }
        let choices: [Choice]
        let usage: UsageWire?
    }
}
