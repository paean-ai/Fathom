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

/// Token usage for a completion or a whole run.
public struct Usage: Sendable, Equatable {
    public var promptTokens: Int
    public var completionTokens: Int
    public var totalTokens: Int
    public init(prompt: Int = 0, completion: Int = 0, total: Int? = nil) {
        promptTokens = prompt; completionTokens = completion
        totalTokens = total ?? (prompt + completion)
    }
    public static func + (a: Usage, b: Usage) -> Usage {
        Usage(prompt: a.promptTokens + b.promptTokens,
              completion: a.completionTokens + b.completionTokens,
              total: a.totalTokens + b.totalTokens)
    }
}

/// A single assistant completion (text and/or tool calls), with optional usage.
public struct Completion: Sendable, Equatable {
    public let content: String?
    public let toolCalls: [ToolCall]
    public let usage: Usage?
    public init(content: String?, toolCalls: [ToolCall] = [], usage: Usage? = nil) {
        self.content = content; self.toolCalls = toolCalls; self.usage = usage
    }
    public var wantsTools: Bool { !toolCalls.isEmpty }
}

/// Why the tool-calling loop ended.
public enum FinishReason: Equatable, Sendable {
    case natural        // the model stopped requesting tools
    case roundLimit     // ran out of rounds
    case noProgress     // two rounds added nothing new
    case budget         // the token budget was reached
    case cancelled      // the task was cancelled
}

/// The result of an orchestrated run.
public struct RunResult: Sendable {
    public let answer: String
    public let messages: [ChatMessage]   // full transcript incl. tool results
    public let toolCallCount: Int
    public let finish: FinishReason
    /// The decomposed steps, when planning was enabled (empty otherwise).
    public let plan: [String]
    /// True when the critic flagged the first answer and it was revised.
    public let revised: Bool
    /// Cumulative token usage across every model call in the run.
    public let usage: Usage
    public init(answer: String, messages: [ChatMessage], toolCallCount: Int,
                finish: FinishReason, plan: [String] = [], revised: Bool = false,
                usage: Usage = Usage()) {
        self.answer = answer; self.messages = messages; self.toolCallCount = toolCallCount
        self.finish = finish; self.plan = plan; self.revised = revised; self.usage = usage
    }
}

/// A reviewer's verdict on a draft answer (the VERIFY phase).
public enum CriticVerdict: Equatable, Sendable {
    case pass               // the answer is correct/complete/grounded
    case revise(String)     // needs work — carries the reviewer's feedback
}
