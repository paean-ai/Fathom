import Foundation

/// A human-in-the-loop decision for a mutating tool call.
public enum ToolApproval: Sendable, Equatable {
    case allow
    case deny(String)   // carries a reason fed back to the model
}

/// The agent core: runs the ACT loop (call tools until the model is ready to answer),
/// with the safety rails of a production agent — never repeat an identical tool call,
/// stop after two no-progress rounds, cap total rounds — PLUS human-in-the-loop
/// approval for mutating tools and concurrent execution of independent tool calls.
/// App-agnostic: supply any `LLMClient` and `[OrchestratorTool]`.
public struct Orchestrator: Sendable {
    public let client: LLMClient
    public var maxRounds: Int
    /// Status callback for UI (e.g. "Searching: …"). Optional.
    public var onStatus: @Sendable (String) -> Void
    /// Fires after EACH tool call with its result — the seam a host uses to collect
    /// side effects (e.g. citations) as the loop runs, without owning the loop itself.
    public var onObservation: @Sendable (Observation) -> Void
    /// Consulted before a MUTATING tool runs (human-in-the-loop). Return `.deny(reason)`
    /// to block it; the reason is fed back to the model so it can adapt. Non-mutating
    /// tools are never gated. Defaults to auto-allow.
    public var approval: @Sendable (ToolCall) async -> ToolApproval
    /// PLAN phase: when true, the agent first decomposes the goal into steps and works
    /// through them (think before acting). Off by default.
    public var planning: Bool
    /// VERIFY phase: when true, a critic reviews the draft answer and the agent revises
    /// once if it falls short (reflection). Off by default.
    public var critic: Bool

    public init(client: LLMClient, maxRounds: Int = 8,
                onStatus: @escaping @Sendable (String) -> Void = { _ in },
                onObservation: @escaping @Sendable (Observation) -> Void = { _ in },
                approval: @escaping @Sendable (ToolCall) async -> ToolApproval = { _ in .allow },
                planning: Bool = false, critic: Bool = false) {
        self.client = client; self.maxRounds = maxRounds
        self.onStatus = onStatus; self.onObservation = onObservation; self.approval = approval
        self.planning = planning; self.critic = critic
    }

    /// One tool call and its outcome, reported to `onObservation`.
    public struct Observation: Sendable, Equatable {
        public let toolName: String
        public let arguments: String   // raw JSON the model sent
        public let result: String      // the tool's textual result (or the prior result on a repeat)
        public let isRepeat: Bool       // true when this exact call already ran this turn (skipped re-execution)
        public let approved: Bool       // false when a mutating call was denied by `approval`
        public init(toolName: String, arguments: String, result: String,
                    isRepeat: Bool, approved: Bool = true) {
            self.toolName = toolName; self.arguments = arguments
            self.result = result; self.isRepeat = isRepeat; self.approved = approved
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

        // PLAN phase — decompose the goal first, then let the loop work the steps.
        var plan: [String] = []
        if planning {
            onStatus("Planning…")
            plan = try await makePlan(query: query)
            if !plan.isEmpty {
                let numbered = plan.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
                convo.append(ChatMessage(role: .system,
                    content: "PLAN — work through these steps with the right tool for each, then answer:\n\(numbered)"))
            }
        }

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

            // 1) CLASSIFY each call: a repeat (de-duped), a denied mutation, or runnable.
            //    Approval is awaited here, sequentially, so a human prompt stays orderly.
            enum Outcome { case repeated(String); case denied(String); case run(OrchestratorTool?) }
            var plan: [(call: ToolCall, sig: String, outcome: Outcome)] = []
            for call in completion.toolCalls {
                let sig = Self.callSignature(name: call.name, arguments: call.arguments)
                if let prior = executed[sig] { plan.append((call, sig, .repeated(prior))); continue }
                let tool = byName[call.name]
                if let tool, tool.isMutating, case let .deny(reason) = await approval(call) {
                    plan.append((call, sig, .denied(reason))); continue
                }
                plan.append((call, sig, .run(tool)))
            }

            // 2) EXECUTE the runnable calls CONCURRENTLY — independent tools shouldn't
            //    serialize. Results are gathered by index so transcript order is stable.
            var results: [Int: String] = [:]
            await withTaskGroup(of: (Int, String).self) { group in
                for (i, step) in plan.enumerated() {
                    guard case let .run(tool) = step.outcome else { continue }
                    onStatus("Running \(step.call.name)…")
                    let call = step.call
                    group.addTask {
                        if let tool { return (i, await tool.invoke(arguments: call.arguments)) }
                        return (i, "Unknown tool '\(call.name)'.")
                    }
                }
                for await (i, r) in group { results[i] = r }
            }

            // 3) THREAD results back in the model's original call order.
            var fresh = 0
            for (i, step) in plan.enumerated() {
                switch step.outcome {
                case let .repeated(prior):
                    onObservation(Observation(toolName: step.call.name, arguments: step.call.arguments,
                                              result: prior, isRepeat: true))
                    convo.append(ChatMessage(role: .tool,
                        content: "(Already called \(step.call.name) with these exact arguments. Result was:\n\(prior)\nDon't repeat it — use it, try different arguments/another tool, or answer.)",
                        toolCallID: step.call.id))
                case let .denied(reason):
                    fresh += 1   // a human decision IS progress — don't count it as a stall
                    onObservation(Observation(toolName: step.call.name, arguments: step.call.arguments,
                                              result: "declined: \(reason)", isRepeat: false, approved: false))
                    convo.append(ChatMessage(role: .tool,
                        content: "Action declined by the user (\(reason)). Do not retry it — continue with another approach or finish.",
                        toolCallID: step.call.id))
                case .run:
                    let result = results[i] ?? "(no result)"
                    fresh += 1; calls += 1
                    executed[step.sig] = result
                    onObservation(Observation(toolName: step.call.name, arguments: step.call.arguments,
                                              result: result, isRepeat: false))
                    convo.append(ChatMessage(role: .tool, content: result, toolCallID: step.call.id))
                }
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
        var answer: String
        if let naturalAnswer {
            answer = naturalAnswer
        } else {
            let final = try await client.complete(messages: convo, tools: [])
            answer = final.content ?? ""
        }

        // VERIFY phase — a critic reviews the draft; revise once if it falls short.
        var revised = false
        if critic, !answer.isEmpty {
            onStatus("Reviewing…")
            if case let .revise(feedback) = try await runCritic(query: query, answer: answer) {
                convo.append(ChatMessage(role: .system,
                    content: "A reviewer flagged the answer: \(feedback)\nRevise it to fully address this. Answer directly."))
                let redo = try await client.complete(messages: convo, tools: [])
                let improved = redo.content ?? ""
                if !improved.isEmpty { answer = improved; revised = true }
            }
        }

        return RunResult(answer: answer, messages: convo, toolCallCount: calls,
                         finish: finish, plan: plan, revised: revised)
    }

    // MARK: plan & verify phases

    /// Ask the model to decompose the goal into a short ordered list of steps.
    private func makePlan(query: String) async throws -> [String] {
        let msgs = [
            ChatMessage(role: .system, content: "You are a planner. Break the user's request into 2–6 short imperative steps. Reply with a numbered list and nothing else. If the request is trivial, reply with a single step."),
            ChatMessage(role: .user, content: query),
        ]
        let c = try await client.complete(messages: msgs, tools: [])
        return Self.parsePlanSteps(c.content ?? "")
    }

    /// Ask a strict reviewer whether the draft answer is good enough.
    private func runCritic(query: String, answer: String) async throws -> CriticVerdict {
        let msgs = [
            ChatMessage(role: .system, content: "You are a strict reviewer. Given the request and the agent's answer, decide if the answer is correct, complete, and grounded. If it is, reply exactly 'PASS'. Otherwise reply 'REVISE: <what is missing or wrong>'."),
            ChatMessage(role: .user, content: "Request: \(query)\n\nAnswer: \(answer)"),
        ]
        let c = try await client.complete(messages: msgs, tools: [])
        return Self.parseCritic(c.content ?? "")
    }

    /// Parse a model's plan reply into clean steps. Prefers genuine list items (so a
    /// preamble/closing line isn't mistaken for a step), strips numbering/bullets, and
    /// de-duplicates. Pure → unit-testable.
    public static func parsePlanSteps(_ text: String) -> [String] {
        func strip(_ t: String) -> String {
            t.replacingOccurrences(of: #"^\d+[\.\)]\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^[-•*]\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let marked = lines.filter { $0.range(of: #"^(\d+[\.\)]|[-•*])\s+"#, options: .regularExpression) != nil }
        let source = marked.count >= 2 ? marked : lines
        var seen = Set<String>(); var out: [String] = []
        for line in source {
            let s = strip(line)
            if s.count >= 2, seen.insert(s.lowercased()).inserted { out.append(s) }
        }
        return out
    }

    /// Parse a critic reply into a verdict. "PASS"/"OK" → pass; "REVISE: …" → revise with
    /// the feedback; anything ambiguous defaults to pass (don't block on noise). Pure.
    public static func parseCritic(_ text: String) -> CriticVerdict {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()
        if upper.hasPrefix("PASS") || upper == "OK" || upper.hasPrefix("OK.") { return .pass }
        if upper.hasPrefix("REVISE") {
            let after = trimmed.drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces)
            return .revise(after.isEmpty ? "the answer needs to be more complete" : after)
        }
        return .pass
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
