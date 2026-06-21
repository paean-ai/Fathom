import Foundation

/// A reusable AGENT: a model + system prompt + tools + policies, bundled so you can
/// run many queries against the same configuration. This is the high-level entry point —
/// `Orchestrator` is the engine it drives.
///
/// ```swift
/// let agent = Agent(client: DeepSeekClient(config: cfg),
///                   systemPrompt: "You are a research assistant.",
///                   tools: [search])
/// let answer = try await agent.run("What changed in Q3?").answer
///
/// // Or hold a multi-turn conversation:
/// let thread = agent.thread()
/// _ = try await thread.send("Summarize the report.")
/// _ = try await thread.send("Now compare it to last year.")   // remembers the first turn
/// ```
public struct Agent: Sendable {
    public var systemPrompt: String
    public var tools: [OrchestratorTool]
    public var orchestrator: Orchestrator

    public init(client: LLMClient,
                systemPrompt: String,
                tools: [OrchestratorTool] = [],
                maxRounds: Int = 8,
                onStatus: @escaping @Sendable (String) -> Void = { _ in },
                onObservation: @escaping @Sendable (Orchestrator.Observation) -> Void = { _ in },
                approval: @escaping @Sendable (ToolCall) async -> ToolApproval = { _ in .allow }) {
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.orchestrator = Orchestrator(client: client, maxRounds: maxRounds,
                                         onStatus: onStatus, onObservation: onObservation,
                                         approval: approval)
    }

    /// Run a single query (optionally with prior `history`) to completion.
    public func run(_ query: String, history: [ChatMessage] = []) async throws -> RunResult {
        try await orchestrator.run(systemPrompt: systemPrompt, query: query,
                                   history: history, tools: tools)
    }

    /// Open a stateful, multi-turn conversation backed by this agent.
    public func thread() -> Thread { Thread(agent: self) }
}

/// A multi-turn conversation with memory. Each `send` runs the agent with the prior
/// turns as history, then appends the new user/assistant exchange. Thread-safe.
public final class Thread: @unchecked Sendable {
    private let agent: Agent
    private let lock = NSLock()
    private var history: [ChatMessage] = []

    public init(agent: Agent) { self.agent = agent }

    /// The running user/assistant transcript (compact — tool calls aren't replayed).
    public var messages: [ChatMessage] {
        lock.lock(); defer { lock.unlock() }; return history
    }

    /// Reset the conversation memory.
    public func reset() { lock.lock(); history = []; lock.unlock() }

    /// Send a message; the agent answers with the prior turns in context, and the
    /// exchange is remembered for the next turn.
    @discardableResult
    public func send(_ query: String) async throws -> RunResult {
        let prior = messages
        let result = try await agent.run(query, history: prior)
        record(query: query, answer: result.answer)
        return result
    }

    /// Append one exchange under the lock (synchronous, so NSLock is safe here).
    private func record(query: String, answer: String) {
        lock.lock()
        history.append(ChatMessage(role: .user, content: query))
        history.append(ChatMessage(role: .assistant, content: answer))
        lock.unlock()
    }
}
