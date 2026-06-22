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
                planning: Bool = false,
                critic: Bool = false,
                tokenBudget: Int? = nil,
                outputGuardrail: @escaping @Sendable (String) async -> GuardrailResult = { _ in .pass },
                maxGuardrailRetries: Int = 1,
                onStatus: @escaping @Sendable (String) -> Void = { _ in },
                onObservation: @escaping @Sendable (Orchestrator.Observation) -> Void = { _ in },
                approval: @escaping @Sendable (ToolCall) async -> ToolApproval = { _ in .allow }) {
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.orchestrator = Orchestrator(client: client, maxRounds: maxRounds,
                                         onStatus: onStatus, onObservation: onObservation,
                                         approval: approval, planning: planning, critic: critic,
                                         tokenBudget: tokenBudget,
                                         outputGuardrail: outputGuardrail, maxGuardrailRetries: maxGuardrailRetries)
    }

    /// Run a single query (optionally with prior `history`) to completion.
    public func run(_ query: String, history: [ChatMessage] = []) async throws -> RunResult {
        try await orchestrator.run(systemPrompt: systemPrompt, query: query,
                                   history: history, tools: tools)
    }

    /// Open a stateful, multi-turn conversation backed by this agent. Pass `contextLimit`
    /// (in characters) to auto-compact older turns into a running summary once the
    /// transcript grows past it — so a long-running conversation stays within the window.
    public func thread(contextLimit: Int? = nil, keepRecent: Int = 6) -> Thread {
        Thread(agent: self, contextLimit: contextLimit, keepRecent: keepRecent)
    }
}

/// A multi-turn conversation with memory. Each `send` runs the agent with the prior turns
/// as history, then appends the new exchange. Optionally COMPACTS: once the transcript
/// exceeds `contextLimit` characters, the oldest turns are summarized (by the model) into
/// one running summary message while a verbatim recent tail is kept — so very long
/// conversations don't blow the context window. Thread-safe.
public final class Thread: @unchecked Sendable {
    private let agent: Agent
    private let contextLimit: Int?     // chars; nil ⇒ never compact
    private let keepRecent: Int        // messages kept verbatim after a compaction
    private let lock = NSLock()
    private var history: [ChatMessage] = []
    private var _compactions = 0

    public init(agent: Agent, contextLimit: Int? = nil, keepRecent: Int = 6) {
        self.agent = agent; self.contextLimit = contextLimit; self.keepRecent = max(2, keepRecent)
    }

    /// The running transcript (a leading summary message may be present after compaction).
    public var messages: [ChatMessage] {
        lock.lock(); defer { lock.unlock() }; return history
    }

    /// How many times the transcript has been compacted.
    public var compactions: Int { lock.lock(); defer { lock.unlock() }; return _compactions }

    /// Reset the conversation memory.
    public func reset() { lock.lock(); history = []; _compactions = 0; lock.unlock() }

    /// Send a message; the agent answers with the prior turns in context, the exchange is
    /// remembered, and the transcript is compacted if it has grown too large.
    @discardableResult
    public func send(_ query: String) async throws -> RunResult {
        let prior = messages
        let result = try await agent.run(query, history: prior)
        record(query: query, answer: result.answer)
        try await compactIfNeeded()
        return result
    }

    /// Append one exchange under the lock (synchronous, so NSLock is safe here).
    private func record(query: String, answer: String) {
        lock.lock()
        history.append(ChatMessage(role: .user, content: query))
        history.append(ChatMessage(role: .assistant, content: answer))
        lock.unlock()
    }

    /// Summarize the oldest turns into one message when the transcript is too large.
    private func compactIfNeeded() async throws {
        let current = messages
        guard let limit = contextLimit, Thread.estimateChars(current) > limit else { return }
        let (toSummarize, keep) = Thread.partition(current, keepRecent: keepRecent)
        guard !toSummarize.isEmpty else { return }

        let transcript = toSummarize.map { "\($0.role.rawValue): \($0.content)" }.joined(separator: "\n")
        let msgs = [
            ChatMessage(role: .system, content: "Summarize the earlier conversation below into a compact paragraph that preserves key facts, decisions, names, numbers, and open threads. Output ONLY the summary."),
            ChatMessage(role: .user, content: transcript),
        ]
        let c = try await agent.orchestrator.client.complete(messages: msgs, tools: [])
        let summary = (c.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return }
        applyCompaction(summary: summary, keep: keep)
    }

    /// Replace the transcript with [summary] + tail, under the lock (synchronous).
    private func applyCompaction(summary: String, keep: [ChatMessage]) {
        lock.lock()
        history = [ChatMessage(role: .system, content: "Summary of earlier conversation: \(summary)")] + keep
        _compactions += 1
        lock.unlock()
    }

    /// Total characters across message contents — a cheap size proxy. Pure → testable.
    static func estimateChars(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + $1.content.count }
    }

    /// Split into the older messages to summarize and the recent tail to keep verbatim.
    /// Pure → testable.
    static func partition(_ messages: [ChatMessage], keepRecent: Int) -> (toSummarize: [ChatMessage], keep: [ChatMessage]) {
        guard messages.count > keepRecent else { return ([], messages) }
        let split = messages.count - keepRecent
        return (Array(messages[..<split]), Array(messages[split...]))
    }
}
