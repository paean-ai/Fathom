import Foundation

/// A reusable DeepSeek tool-calling orchestrator. Runs the ACT loop (call tools until
/// the model is ready to answer), with the safety rails learned from Claude Code/Codex:
/// never repeat an identical tool call, stop after two no-progress rounds, and cap the
/// total rounds. App-agnostic — supply any `LLMClient` and `[OrchestratorTool]`.
public struct Orchestrator: Sendable {
    public let client: LLMClient
    public var maxRounds: Int
    /// Status callback for UI (e.g. "Searching: …"). Optional.
    public var onStatus: @Sendable (String) -> Void
    /// Fires after EACH tool call with its result — the seam a host uses to collect
    /// side effects (e.g. citations) as the loop runs, without owning the loop itself.
    public var onObservation: @Sendable (Observation) -> Void

    public init(client: LLMClient, maxRounds: Int = 8,
                onStatus: @escaping @Sendable (String) -> Void = { _ in },
                onObservation: @escaping @Sendable (Observation) -> Void = { _ in }) {
        self.client = client; self.maxRounds = maxRounds
        self.onStatus = onStatus; self.onObservation = onObservation
    }

    /// One tool call and its outcome, reported to `onObservation`.
    public struct Observation: Sendable, Equatable {
        public let toolName: String
        public let arguments: String   // raw JSON the model sent
        public let result: String      // the tool's textual result (or the prior result on a repeat)
        public let isRepeat: Bool       // true when this exact call already ran this turn (skipped re-execution)
        public init(toolName: String, arguments: String, result: String, isRepeat: Bool) {
            self.toolName = toolName; self.arguments = arguments
            self.result = result; self.isRepeat = isRepeat
        }
    }

    /// Run the loop, then ask for a final tool-free answer. `history` precedes `query`.
    public func run(systemPrompt: String, query: String,
                    history: [ChatMessage] = [], tools: [OrchestratorTool]) async throws -> RunResult {
        let byName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let schemas = tools.map(\.schema)

        var convo: [ChatMessage] = [ChatMessage(role: .system, content: systemPrompt)]
        convo += history.filter { $0.role == .user || $0.role == .assistant || $0.role == .system }
        convo.append(ChatMessage(role: .user, content: query))

        var executed: [String: String] = [:]   // de-dup: signature → prior result
        var calls = 0
        var stalls = 0
        var finish: FinishReason = .roundLimit
        var naturalAnswer: String?   // set when the model answers in-loop (no tools)

        for _ in 0..<maxRounds {
            let completion = try await client.complete(messages: convo, tools: schemas)
            guard completion.wantsTools else {
                naturalAnswer = completion.content ?? ""
                finish = .natural
                break
            }

            convo.append(ChatMessage(role: .assistant, content: completion.content ?? "",
                                     toolCalls: completion.toolCalls))

            var fresh = 0
            for call in completion.toolCalls {
                let sig = Self.callSignature(name: call.name, arguments: call.arguments)
                if let prior = executed[sig] {
                    onObservation(Observation(toolName: call.name, arguments: call.arguments,
                                              result: prior, isRepeat: true))
                    convo.append(ChatMessage(role: .tool,
                        content: "(Already called \(call.name) with these exact arguments. Result was:\n\(prior)\nDon't repeat it — use it, try different arguments/another tool, or answer.)",
                        toolCallID: call.id))
                    continue
                }
                fresh += 1
                calls += 1
                onStatus("Running \(call.name)…")
                let result: String
                if let tool = byName[call.name] { result = await tool.invoke(arguments: call.arguments) }
                else { result = "Unknown tool '\(call.name)'." }
                executed[sig] = result
                onObservation(Observation(toolName: call.name, arguments: call.arguments,
                                          result: result, isRepeat: false))
                convo.append(ChatMessage(role: .tool, content: result, toolCallID: call.id))
            }

            if Self.isStall(freshCalls: fresh) {
                stalls += 1
                if stalls >= 2 {
                    convo.append(ChatMessage(role: .system,
                        content: "Two rounds added nothing new. Answer now with what you have; be honest about gaps."))
                    finish = .noProgress
                    break
                }
            } else { stalls = 0 }
        }

        // If the model already answered in-loop (no tools), that text IS the answer.
        // Otherwise (round/no-progress cap) ask once more, tool-free, for a closing answer.
        let answer: String
        if let naturalAnswer {
            answer = naturalAnswer
        } else {
            let final = try await client.complete(messages: convo, tools: [])
            answer = final.content ?? ""
        }
        return RunResult(answer: answer, messages: convo, toolCallCount: calls, finish: finish)
    }

    // MARK: pure helpers (loop safety rails)

    /// A stable signature so identical calls (even with reordered JSON keys) collapse.
    public static func callSignature(name: String, arguments: String) -> String {
        if let data = arguments.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let norm = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
           let s = String(data: norm, encoding: .utf8) {
            return name + ":" + s
        }
        return name + ":" + arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A round made no progress when it ran no fresh (non-repeat) calls.
    public static func isStall(freshCalls: Int) -> Bool { freshCalls == 0 }

    /// A short user-facing note for a non-obvious finish (nil for a clean finish).
    public static func finishNote(_ r: FinishReason) -> String? {
        switch r {
        case .natural:    return nil
        case .noProgress: return "Wrapping up — no new information in the last steps."
        case .roundLimit: return "Reached the step limit — answering with what I have."
        }
    }
}
