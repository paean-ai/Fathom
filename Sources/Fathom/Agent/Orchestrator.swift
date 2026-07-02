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
    /// Optional cap on total tokens for the run. Once cumulative usage reaches it, the
    /// loop stops requesting tools and produces a final answer (finish = `.budget`). nil =
    /// unbounded. Requires the client to report usage.
    public var tokenBudget: Int?
    /// Output GUARDRAIL: validate the final answer; return `.retry(reason)` to regenerate
    /// it (up to `maxGuardrailRetries`) with the reason fed back. Deterministic and
    /// host-supplied — enforce JSON-parses, required fields, length, no-PII, etc. Defaults
    /// to always-pass.
    public var outputGuardrail: @Sendable (String) async -> GuardrailResult
    /// How many times the output guardrail may force a regeneration.
    public var maxGuardrailRetries: Int
    /// Context shaping: cap the size (in characters) of OLDER tool-result messages before each model
    /// call so a long tool-using run can't overflow the context window. 0 disables. A long run appends
    /// every tool result to the transcript; without this, big outputs (file reads, command output)
    /// accumulate unbounded. See `shapeContext`.
    public var maxToolResultChars: Int
    /// How many of the most-recent tool results to keep at full size (the model usually needs only the
    /// latest outputs verbatim). Older ones beyond this are capped to `maxToolResultChars`.
    public var keepRecentToolResultsFull: Int
    /// IN-RUN auto-compaction: when the live prompt exceeds this many tokens (actual usage reported
    /// by the client, falling back to a ≈4-chars/token estimate), the MIDDLE of the transcript is
    /// summarized by the model into one recap message and the loop continues — so a single long run
    /// survives past the context window, not just truncated tool results (`maxToolResultChars`) or
    /// between-turn compaction (`Thread`). The system prompt, the first user message (the goal) and
    /// the recent tail stay verbatim. 0 disables (the default). Applies to streaming runs too.
    public var compactionThresholdTokens: Int
    /// How many trailing messages stay verbatim when an in-run compaction fires (extended backward
    /// if needed so the tail never starts with an orphaned tool result).
    public var keepRecentOnCompaction: Int

    public init(client: LLMClient, maxRounds: Int = 8,
                onStatus: @escaping @Sendable (String) -> Void = { _ in },
                onObservation: @escaping @Sendable (Observation) -> Void = { _ in },
                approval: @escaping @Sendable (ToolCall) async -> ToolApproval = { _ in .allow },
                planning: Bool = false, critic: Bool = false, tokenBudget: Int? = nil,
                outputGuardrail: @escaping @Sendable (String) async -> GuardrailResult = { _ in .pass },
                maxGuardrailRetries: Int = 1,
                maxToolResultChars: Int = 8_000, keepRecentToolResultsFull: Int = 3,
                compactionThresholdTokens: Int = 0, keepRecentOnCompaction: Int = 8) {
        self.client = client; self.maxRounds = maxRounds
        self.onStatus = onStatus; self.onObservation = onObservation; self.approval = approval
        self.planning = planning; self.critic = critic; self.tokenBudget = tokenBudget
        self.outputGuardrail = outputGuardrail; self.maxGuardrailRetries = maxGuardrailRetries
        self.maxToolResultChars = maxToolResultChars
        self.keepRecentToolResultsFull = keepRecentToolResultsFull
        self.compactionThresholdTokens = compactionThresholdTokens
        self.keepRecentOnCompaction = keepRecentOnCompaction
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

        var usage = Usage()                       // cumulative across every model call

        // PLAN phase — decompose the goal first, then let the loop work the steps.
        var plan: [String] = []
        if planning {
            onStatus("Planning…")
            let (steps, u) = try await makePlan(query: query)
            usage = usage + u
            plan = steps
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
        var compactions = 0
        var lastPromptTokens = 0     // actual prompt size the client last reported

        for _ in 0..<maxRounds {
            // Stop gracefully on cancellation or when the token budget is reached.
            if Task.isCancelled { finish = .cancelled; break }
            if let budget = tokenBudget, usage.totalTokens >= budget { finish = .budget; break }

            // COMPACT when the transcript has outgrown the threshold (prefer the size the
            // client actually reported; the char estimate covers the tool results appended
            // since then, and clients that don't report usage at all).
            if compactionThresholdTokens > 0,
               max(lastPromptTokens, Self.estimateTokens(convo)) >= compactionThresholdTokens,
               await compactInRun(&convo, usage: &usage) {
                compactions += 1
                lastPromptTokens = 0   // stale — the transcript just shrank
            }

            let shaped = Self.shapeContext(convo, maxToolResultChars: maxToolResultChars,
                                           keepRecentFull: keepRecentToolResultsFull)
            let completion = try await client.complete(messages: shaped, tools: schemas)
            usage = usage + (completion.usage ?? Usage())
            lastPromptTokens = completion.usage?.promptTokens ?? lastPromptTokens
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
        // On cancellation, return the best we have without spending more tokens.
        // Otherwise (round/no-progress/budget cap) ask once more, tool-free, to close out.
        var answer: String
        if finish == .cancelled {
            answer = naturalAnswer ?? ""
        } else if let naturalAnswer {
            answer = naturalAnswer
        } else {
            // The close-out call must fit the window too.
            if compactionThresholdTokens > 0,
               max(lastPromptTokens, Self.estimateTokens(convo)) >= compactionThresholdTokens,
               await compactInRun(&convo, usage: &usage) {
                compactions += 1
            }
            let shaped = Self.shapeContext(convo, maxToolResultChars: maxToolResultChars,
                                           keepRecentFull: keepRecentToolResultsFull)
            let final = try await client.complete(messages: shaped, tools: [])
            usage = usage + (final.usage ?? Usage())
            answer = final.content ?? ""
        }

        // VERIFY phase — a critic reviews the draft; revise once if it falls short.
        // Skipped on cancellation.
        var revised = false
        if critic, finish != .cancelled, !answer.isEmpty {
            onStatus("Reviewing…")
            let (verdict, cu) = try await runCritic(query: query, answer: answer)
            usage = usage + cu
            if case let .revise(feedback) = verdict {
                convo.append(ChatMessage(role: .system,
                    content: "A reviewer flagged the answer: \(feedback)\nRevise it to fully address this. Answer directly."))
                let redo = try await client.complete(messages: convo, tools: [])
                usage = usage + (redo.usage ?? Usage())
                let improved = redo.content ?? ""
                if !improved.isEmpty { answer = improved; revised = true }
            }
        }

        // GUARDRAIL phase — validate the answer; regenerate on failure (bounded). Skipped
        // on cancellation.
        var guardrailRetries = 0
        if finish != .cancelled, !answer.isEmpty {
            for _ in 0..<max(0, maxGuardrailRetries) {
                guard case let .retry(reason) = await outputGuardrail(answer) else { break }
                guardrailRetries += 1
                onStatus("Checking the answer…")
                convo.append(ChatMessage(role: .system,
                    content: "Your answer didn't meet a requirement: \(reason)\nProduce a corrected answer that satisfies it. Answer directly."))
                let redo = try await client.complete(messages: convo, tools: [])
                usage = usage + (redo.usage ?? Usage())
                let improved = redo.content ?? ""
                if !improved.isEmpty { answer = improved }
            }
        }

        return RunResult(answer: answer, messages: convo, toolCallCount: calls,
                         finish: finish, plan: plan, revised: revised, usage: usage,
                         guardrailRetries: guardrailRetries, compactions: compactions)
    }

    // MARK: in-run compaction

    /// Summarize the middle of the transcript into one recap message, in place. FAILURE-SAFE:
    /// on any shortfall (nothing worth summarizing, the model call throws, an empty summary)
    /// the transcript is left untouched and the run simply continues — compaction must never
    /// kill a run it exists to save. Returns whether a compaction was applied. (Internal so
    /// the streaming loop in Streaming.swift shares it.)
    func compactInRun(_ convo: inout [ChatMessage], usage: inout Usage) async -> Bool {
        let split = Self.compactionSplit(convo, keepRecent: keepRecentOnCompaction)
        guard !split.middle.isEmpty else { return false }
        onStatus("Compacting context…")
        let msgs = [
            ChatMessage(role: .system, content: "You compress an agent's working transcript mid-task. Summarize the steps below into a compact brief that preserves: the goal and constraints, what was tried, key facts/paths/numbers from tool results, what succeeded or failed, and what remains to be done. Output ONLY the brief."),
            ChatMessage(role: .user, content: Self.renderForSummary(split.middle)),
        ]
        guard let c = try? await client.complete(messages: msgs, tools: []) else { return false }
        usage = usage + (c.usage ?? Usage())
        let summary = (c.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return false }
        convo = split.head
            + [ChatMessage(role: .system,
                content: "CONTEXT RECAP — earlier steps were compacted to stay within the context window:\n\(summary)")]
            + split.tail
        return true
    }

    // MARK: plan & verify phases

    /// Ask the model to decompose the goal into steps (returns steps + token usage).
    private func makePlan(query: String) async throws -> (steps: [String], usage: Usage) {
        let msgs = [
            ChatMessage(role: .system, content: "You are a planner. Break the user's request into 2–6 short imperative steps. Reply with a numbered list and nothing else. If the request is trivial, reply with a single step."),
            ChatMessage(role: .user, content: query),
        ]
        let c = try await client.complete(messages: msgs, tools: [])
        return (Self.parsePlanSteps(c.content ?? ""), c.usage ?? Usage())
    }

    /// Ask a strict reviewer whether the draft answer is good enough (verdict + usage).
    private func runCritic(query: String, answer: String) async throws -> (verdict: CriticVerdict, usage: Usage) {
        let msgs = [
            ChatMessage(role: .system, content: "You are a strict reviewer. Given the request and the agent's answer, decide if the answer is correct, complete, and grounded. If it is, reply exactly 'PASS'. Otherwise reply 'REVISE: <what is missing or wrong>'."),
            ChatMessage(role: .user, content: "Request: \(query)\n\nAnswer: \(answer)"),
        ]
        let c = try await client.complete(messages: msgs, tools: [])
        return (Self.parseCritic(c.content ?? ""), c.usage ?? Usage())
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

    /// Read-time context shaper: a long tool-using run appends every tool result to the transcript and
    /// will eventually overflow the context window. Cap the size of OLDER tool-result messages (keeping
    /// the `keepRecentFull` most recent results intact — the model usually needs only the latest outputs
    /// verbatim) and mark the elision so the model knows content was dropped. Non-tool messages are
    /// untouched; the caller's stored transcript is not mutated (this returns a projected copy). Pure.
    public static func shapeContext(_ messages: [ChatMessage],
                                    maxToolResultChars: Int,
                                    keepRecentFull: Int) -> [ChatMessage] {
        guard maxToolResultChars > 0 else { return messages }
        let toolIdx = messages.indices.filter { messages[$0].role == .tool }
        guard toolIdx.count > max(0, keepRecentFull) else { return messages }
        let keep = Set(toolIdx.suffix(max(0, keepRecentFull)))
        var out = messages
        for i in toolIdx where !keep.contains(i) {
            let c = out[i].content
            if c.count > maxToolResultChars {
                out[i].content = String(c.prefix(maxToolResultChars))
                    + "\n…[truncated \(c.count - maxToolResultChars) chars of an earlier tool result]"
            }
        }
        return out
    }

    /// Split for in-run compaction. `head` = the leading system message(s) plus the first user
    /// message right after them (the goal, kept verbatim). `tail` = the `keepRecent` most recent
    /// messages, extended backward if needed so it never STARTS with a `.tool` message (a tool
    /// result must follow the assistant turn that called it, or the API rejects the transcript).
    /// `middle` = everything between — what gets summarized. Pure → testable.
    public static func compactionSplit(_ messages: [ChatMessage], keepRecent: Int)
        -> (head: [ChatMessage], middle: [ChatMessage], tail: [ChatMessage]) {
        var headEnd = 0
        while headEnd < messages.count, messages[headEnd].role == .system { headEnd += 1 }
        if headEnd < messages.count, messages[headEnd].role == .user { headEnd += 1 }
        var tailStart = max(headEnd, messages.count - max(0, keepRecent))
        while tailStart > headEnd, tailStart < messages.count, messages[tailStart].role == .tool {
            tailStart -= 1
        }
        return (Array(messages[..<headEnd]),
                Array(messages[headEnd..<tailStart]),
                Array(messages[tailStart...]))
    }

    /// Crude prompt-size estimate (≈4 chars per token, plus per-message overhead) for when the
    /// client hasn't reported real usage. Counts tool-call arguments too. Pure.
    public static func estimateTokens(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { total, m in
            let argChars = m.toolCalls.reduce(0) { $0 + $1.name.count + $1.arguments.count }
            return total + (m.content.count + argChars) / 4 + 8
        }
    }

    /// Render messages as a plain transcript for the compaction summarizer, capping each
    /// message so a pathological tool result can't overflow the summarizer's own window. Pure.
    static func renderForSummary(_ messages: [ChatMessage], perMessageCap: Int = 6_000) -> String {
        messages.map { m in
            var line = "\(m.role.rawValue): \(String(m.content.prefix(perMessageCap)))"
            for c in m.toolCalls { line += "\n  → called \(c.name)(\(String(c.arguments.prefix(500))))" }
            return line
        }.joined(separator: "\n")
    }

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
        case .budget:     return "Reached the token budget — answering with what I have."
        case .cancelled:  return "Cancelled — returning what was gathered so far."
        }
    }
}
