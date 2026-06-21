import Foundation

/// General translation prompt + tool. The prompt is exposed so host apps can reuse the
/// exact wording with their own transport, and `TranslateTool` works for any agent that
/// already has an `LLMClient`.
public enum Translation {
    /// The system prompt for a faithful, preamble-free translation into `language`.
    public static func systemPrompt(to language: String) -> String {
        "You are a precise translator. Translate the user's text into \(language). Preserve meaning, tone, and " +
        "formatting (lists, line breaks). Output ONLY the translation — no preamble, notes, or quotes."
    }
}

/// Built-in tool: translate text into a target language, using the agent's own model.
public struct TranslateTool: OrchestratorTool {
    private let client: LLMClient
    public init(client: LLMClient) { self.client = client }
    public var name: String { "translate" }
    public var toolDescription: String {
        "Translate text into a target language. The output is the translation only."
    }
    public var parameters: [String: Any] {
        ["type": "object",
         "properties": [
            "text": ["type": "string", "description": "the text to translate"],
            "to": ["type": "string", "description": "target language, e.g. French, 中文, Spanish"],
         ],
         "required": ["text", "to"]]
    }
    public func invoke(arguments: String) async -> String {
        guard let text = jsonString(arguments, "text")?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let to = jsonString(arguments, "to")?.trimmingCharacters(in: .whitespacesAndNewlines), !to.isEmpty else {
            return "Missing 'text' or 'to'."
        }
        let messages = [
            ChatMessage(role: .system, content: Translation.systemPrompt(to: to)),
            ChatMessage(role: .user, content: text),
        ]
        guard let completion = try? await client.complete(messages: messages, tools: []),
              let out = completion.content, !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Couldn't translate that right now."
        }
        return out
    }
}
