import Foundation

/// App-agnostic chat primitives for the orchestrator. Mirror DeepSeek's OpenAI-style
/// API but stay independent of any host app.
public enum Role: String, Codable, Sendable {
    case system, user, assistant, tool
}

public struct ChatMessage: Sendable, Equatable {
    public var role: Role
    public var content: String
    /// For assistant turns that request tools.
    public var toolCalls: [ToolCall]
    /// For tool-result turns — which call this answers.
    public var toolCallID: String?

    public init(role: Role, content: String = "", toolCalls: [ToolCall] = [], toolCallID: String? = nil) {
        self.role = role; self.content = content; self.toolCalls = toolCalls; self.toolCallID = toolCallID
    }
}

public struct ToolCall: Sendable, Equatable, Codable {
    public let id: String
    public let name: String
    public let arguments: String   // raw JSON string
    public init(id: String, name: String, arguments: String) {
        self.id = id; self.name = name; self.arguments = arguments
    }
}

/// A single assistant completion (text and/or tool calls).
public struct Completion: Sendable, Equatable {
    public let content: String?
    public let toolCalls: [ToolCall]
    public init(content: String?, toolCalls: [ToolCall] = []) {
        self.content = content; self.toolCalls = toolCalls
    }
    public var wantsTools: Bool { !toolCalls.isEmpty }
}

/// Why the tool-calling loop ended.
public enum FinishReason: Equatable, Sendable {
    case natural        // the model stopped requesting tools
    case roundLimit     // ran out of rounds
    case noProgress     // two rounds added nothing new
}

/// The result of an orchestrated run.
public struct RunResult: Sendable {
    public let answer: String
    public let messages: [ChatMessage]   // full transcript incl. tool results
    public let toolCallCount: Int
    public let finish: FinishReason
}
