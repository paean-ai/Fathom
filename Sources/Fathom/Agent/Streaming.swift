import Foundation

/// One incremental piece of a streamed model response.
public enum StreamDelta: Sendable, Equatable {
    case text(String)        // a chunk of answer text
    case toolCall(ToolCall)  // a fully-assembled tool call (the client reassembles fragments)
    case usage(Usage)        // final token usage, when the API reports it
}

/// An `LLMClient` that can also stream a completion as it's generated. Conform your client
/// to stream the final answer token-by-token; the agent loop uses it when available.
public protocol StreamingLLMClient: LLMClient {
    func stream(messages: [ChatMessage], tools: [[String: Any]]) -> AsyncThrowingStream<StreamDelta, Error>
}

/// An event emitted while an agent runs in streaming mode.
public enum AgentEvent: Sendable {
    case status(String)                       // e.g. "Running search…"
    case toolResult(name: String, result: String)
    case answerDelta(String)                  // a chunk of the final answer
    case finished(RunResult)                  // terminal event with the full result
}

public extension Orchestrator {
    /// Run the agent loop, STREAMING the answer as `AgentEvent`s. Answer text arrives as
    /// `.answerDelta` chunks; tool runs surface as `.status`/`.toolResult`; the stream ends
    /// with `.finished(RunResult)`. If the client isn't a `StreamingLLMClient`, it falls
    /// back to a one-shot run and yields the whole answer once. (Streaming mode applies the
    /// de-dup / no-progress / round-limit / cancellation rails and in-run compaction; planning,
    /// critic and guardrails remain on the non-streaming `run`.)
    func runStreaming(systemPrompt: String, query: String,
                      history: [ChatMessage] = [], tools: [OrchestratorTool]) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let sc = client as? StreamingLLMClient else {
                        let result = try await run(systemPrompt: systemPrompt, query: query, history: history, tools: tools)
                        if !result.answer.isEmpty { continuation.yield(.answerDelta(result.answer)) }
                        continuation.yield(.finished(result))
                        continuation.finish(); return
                    }

                    // Built inside the task so the non-Sendable schema dictionaries aren't
                    // captured across the task boundary.
                    let byName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
                    let schemas = tools.map(\.schema)
                    var convo: [ChatMessage] = [ChatMessage(role: .system, content: systemPrompt)]
                    convo += history.filter { $0.role == .user || $0.role == .assistant || $0.role == .system }
                    convo.append(ChatMessage(role: .user, content: query))

                    var executed: [String: String] = [:]
                    var calls = 0, stalls = 0
                    var finish: FinishReason = .roundLimit
                    var usage = Usage()
                    var answer = ""
                    var compactions = 0
                    var lastPromptTokens = 0

                    rounds: for _ in 0..<maxRounds {
                        if Task.isCancelled { finish = .cancelled; break }

                        // Same in-run compaction as the non-streaming loop: past the threshold,
                        // summarize the transcript middle and keep going.
                        if compactionThresholdTokens > 0,
                           max(lastPromptTokens, Self.estimateTokens(convo)) >= compactionThresholdTokens {
                            continuation.yield(.status("Compacting context…"))
                            if await compactInRun(&convo, usage: &usage) {
                                compactions += 1
                                lastPromptTokens = 0
                            }
                        }

                        var content = "", toolCalls: [ToolCall] = []
                        for try await delta in sc.stream(messages: convo, tools: schemas) {
                            switch delta {
                            case .text(let t):
                                content += t
                                continuation.yield(.answerDelta(t))   // answer turns carry text; tool turns don't
                            case .toolCall(let c): toolCalls.append(c)
                            case .usage(let u): usage = usage + u; lastPromptTokens = u.promptTokens
                            }
                        }

                        if toolCalls.isEmpty { answer = content; finish = .natural; break }

                        convo.append(ChatMessage(role: .assistant, content: content, toolCalls: toolCalls))
                        var fresh = 0
                        for call in toolCalls {
                            let sig = Self.callSignature(name: call.name, arguments: call.arguments)
                            if let prior = executed[sig] {
                                convo.append(ChatMessage(role: .tool,
                                    content: "(Already called \(call.name) with these exact arguments. Result was:\n\(prior)\nDon't repeat it.)",
                                    toolCallID: call.id))
                                continue
                            }
                            fresh += 1; calls += 1
                            continuation.yield(.status("Running \(call.name)…"))
                            let result: String
                            if let tool = byName[call.name] { result = await tool.invoke(arguments: call.arguments) }
                            else { result = "Unknown tool '\(call.name)'." }
                            executed[sig] = result
                            continuation.yield(.toolResult(name: call.name, result: result))
                            convo.append(ChatMessage(role: .tool, content: result, toolCallID: call.id))
                        }

                        if Self.isStall(freshCalls: fresh) {
                            stalls += 1
                            if stalls >= 2 { finish = .noProgress; break rounds }
                        } else { stalls = 0 }
                    }

                    // If the loop ended without a natural answer, stream a closing answer
                    // (compacted first if the transcript has outgrown the window).
                    if answer.isEmpty && finish != .cancelled {
                        if compactionThresholdTokens > 0,
                           max(lastPromptTokens, Self.estimateTokens(convo)) >= compactionThresholdTokens,
                           await compactInRun(&convo, usage: &usage) {
                            compactions += 1
                        }
                        for try await delta in sc.stream(messages: convo, tools: []) {
                            switch delta {
                            case .text(let t): answer += t; continuation.yield(.answerDelta(t))
                            case .usage(let u): usage = usage + u
                            case .toolCall: break
                            }
                        }
                    }

                    let result = RunResult(answer: answer, messages: convo, toolCallCount: calls,
                                           finish: finish, usage: usage, compactions: compactions)
                    continuation.yield(.finished(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public extension Agent {
    /// Stream this agent's answer to a query as `AgentEvent`s.
    func stream(_ query: String, history: [ChatMessage] = []) -> AsyncThrowingStream<AgentEvent, Error> {
        orchestrator.runStreaming(systemPrompt: systemPrompt, query: query, history: history, tools: tools)
    }
}

// MARK: - Real SSE streaming for DeepSeekClient

extension DeepSeekClient: StreamingLLMClient {
    public func stream(messages: [ChatMessage], tools: [[String: Any]]) -> AsyncThrowingStream<StreamDelta, Error> {
        // Build the request synchronously so the task captures only Sendable values
        // (a URLRequest), not the non-Sendable `[[String: Any]]` tool schemas or `self`.
        let request: URLRequest
        do {
            var body: [String: Any] = [
                "model": config.model, "temperature": config.temperature, "stream": true,
                "stream_options": ["include_usage": true],
                "messages": messages.map(Self.wire),
            ]
            if !tools.isEmpty { body["tools"] = tools; body["tool_choice"] = "auto" }
            var req = URLRequest(url: config.baseURL.appendingPathComponent("chat/completions"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            request = req
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, _) = try await URLSession.shared.bytes(for: request)
                    var toolAccum: [Int: (id: String, name: String, args: String)] = [:]
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data) else { continue }
                        if let u = chunk.usage {
                            continuation.yield(.usage(Usage(prompt: u.promptTokens ?? 0, completion: u.completionTokens ?? 0, total: u.totalTokens)))
                        }
                        guard let delta = chunk.choices.first?.delta else { continue }
                        if let c = delta.content, !c.isEmpty { continuation.yield(.text(c)) }
                        for frag in delta.toolCalls ?? [] {
                            var acc = toolAccum[frag.index] ?? (id: "", name: "", args: "")
                            if let id = frag.id { acc.id = id }
                            if let n = frag.function?.name { acc.name = n }
                            if let a = frag.function?.arguments { acc.args += a }
                            toolAccum[frag.index] = acc
                        }
                    }
                    for (_, tc) in toolAccum.sorted(by: { $0.key < $1.key }) where !tc.name.isEmpty {
                        continuation.yield(.toolCall(ToolCall(id: tc.id.isEmpty ? UUID().uuidString : tc.id, name: tc.name, arguments: tc.args)))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct StreamChunk: Decodable {
        struct Choice: Decodable { let delta: Delta }
        struct Delta: Decodable {
            let content: String?
            let toolCalls: [ToolFrag]?
            enum CodingKeys: String, CodingKey { case content, toolCalls = "tool_calls" }
        }
        struct ToolFrag: Decodable {
            let index: Int; let id: String?; let function: Fn?
            struct Fn: Decodable { let name: String?; let arguments: String? }
        }
        struct UsageWire: Decodable {
            let promptTokens: Int?; let completionTokens: Int?; let totalTokens: Int?
            enum CodingKeys: String, CodingKey { case promptTokens = "prompt_tokens", completionTokens = "completion_tokens", totalTokens = "total_tokens" }
        }
        let choices: [Choice]
        let usage: UsageWire?
    }
}
