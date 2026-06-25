import XCTest
@testable import Fathom

/// A scripted LLM: returns queued completions in order, recording what it was sent.
final class MockClient: LLMClient, @unchecked Sendable {
    private var queue: [Completion]
    private(set) var sentMessages: [[ChatMessage]] = []
    init(_ completions: [Completion]) { queue = completions }
    func complete(messages: [ChatMessage], tools: [[String: Any]]) async throws -> Completion {
        sentMessages.append(messages)
        return queue.isEmpty ? Completion(content: "done") : queue.removeFirst()
    }
}

/// Thread-safe counter for the de-dup test's @Sendable tool closure.
final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// Thread-safe collector for observations emitted from the @Sendable hook.
final class ObservationLog: @unchecked Sendable {
    private let lock = NSLock(); private var items: [Orchestrator.Observation] = []
    func append(_ o: Orchestrator.Observation) { lock.lock(); items.append(o); lock.unlock() }
    var all: [Orchestrator.Observation] { lock.lock(); defer { lock.unlock() }; return items }
}

final class OrchestratorTests: XCTestCase {

    private func tool(_ name: String, returns: String, mutating: Bool = false) -> ClosureTool {
        ClosureTool(name: name, description: name, isMutating: mutating) { _ in returns }
    }

    func testRunsToolThenAnswers() async throws {
        let client = MockClient([
            Completion(content: nil, toolCalls: [ToolCall(id: "1", name: "search", arguments: #"{"q":"x"}"#)]),
            Completion(content: "Final answer based on results."),
        ])
        let orch = Orchestrator(client: client)
        let result = try await orch.run(systemPrompt: "sys", query: "find x",
                                        tools: [tool("search", returns: "RESULT")])
        XCTAssertEqual(result.answer, "Final answer based on results.")
        XCTAssertEqual(result.toolCallCount, 1)
        XCTAssertEqual(result.finish, .natural)
        // The tool result was threaded back into the conversation.
        XCTAssertTrue(result.messages.contains { $0.role == .tool && $0.content == "RESULT" })
    }

    func testDeDupesRepeatedCall() async throws {
        // The model (mistakenly) asks for the SAME call twice across two rounds.
        let call = ToolCall(id: "a", name: "search", arguments: #"{"q":"x"}"#)
        let client = MockClient([
            Completion(content: nil, toolCalls: [call]),
            Completion(content: nil, toolCalls: [ToolCall(id: "b", name: "search", arguments: #"{"q":"x"}"#)]),
            Completion(content: "answer"),
        ])
        let counter = Counter()
        let t = ClosureTool(name: "search", description: "s") { _ in counter.bump(); return "R" }
        let orch = Orchestrator(client: client)
        _ = try await orch.run(systemPrompt: "s", query: "q", tools: [t])
        XCTAssertEqual(counter.value, 1, "the repeated identical call is not executed again")
    }

    func testObservationHookReportsEachToolCall() async throws {
        // Round 1 runs `search` (fresh); round 2 repeats the SAME call (de-duped); then answers.
        let client = MockClient([
            Completion(content: nil, toolCalls: [ToolCall(id: "1", name: "search", arguments: #"{"q":"x"}"#)]),
            Completion(content: nil, toolCalls: [ToolCall(id: "2", name: "search", arguments: #"{"q":"x"}"#)]),
            Completion(content: "answer"),
        ])
        let log = ObservationLog()
        let orch = Orchestrator(client: client, onObservation: { log.append($0) })
        _ = try await orch.run(systemPrompt: "s", query: "q", tools: [tool("search", returns: "RESULT")])

        let obs = log.all
        XCTAssertEqual(obs.count, 2, "one observation per tool call (fresh + repeat)")
        XCTAssertEqual(obs.first?.toolName, "search")
        XCTAssertEqual(obs.first?.result, "RESULT")
        XCTAssertEqual(obs.first?.isRepeat, false, "first call is fresh")
        XCTAssertEqual(obs.last?.isRepeat, true, "the identical second call is reported as a repeat")
        XCTAssertEqual(obs.last?.result, "RESULT", "a repeat carries the prior result forward")
    }

    func testNoProgressStops() async throws {
        // Every round the model only repeats an already-run call ⇒ no progress ⇒ stop.
        let repeated = ToolCall(id: "x", name: "noop", arguments: "{}")
        let client = MockClient([
            Completion(content: nil, toolCalls: [repeated]),
            Completion(content: nil, toolCalls: [ToolCall(id: "y", name: "noop", arguments: "{}")]),
            Completion(content: nil, toolCalls: [ToolCall(id: "z", name: "noop", arguments: "{}")]),
            Completion(content: "forced answer"),
        ])
        let orch = Orchestrator(client: client, maxRounds: 10)
        let result = try await orch.run(systemPrompt: "s", query: "q", tools: [tool("noop", returns: "N")])
        XCTAssertEqual(result.finish, .noProgress)
    }

    func testRoundLimitReached() async throws {
        // The model keeps requesting fresh (distinct-args) tools every round; the loop
        // must stop at maxRounds rather than spin forever.
        let client = MockClient([
            Completion(content: nil, toolCalls: [ToolCall(id: "1", name: "s", arguments: #"{"n":1}"#)]),
            Completion(content: nil, toolCalls: [ToolCall(id: "2", name: "s", arguments: #"{"n":2}"#)]),
        ])
        let orch = Orchestrator(client: client, maxRounds: 2)
        let r = try await orch.run(systemPrompt: "s", query: "q", tools: [tool("s", returns: "R")])
        XCTAssertEqual(r.finish, .roundLimit)
    }

    func testCallSignatureAndFinishNote() {
        XCTAssertEqual(Orchestrator.callSignature(name: "t", arguments: #"{"a":1,"b":2}"#),
                       Orchestrator.callSignature(name: "t", arguments: #"{"b":2,"a":1}"#))
        XCTAssertNil(Orchestrator.finishNote(.natural))
        XCTAssertNotNil(Orchestrator.finishNote(.noProgress))
        XCTAssertNotNil(Orchestrator.finishNote(.roundLimit))
    }

    // MARK: context shaping (long-run overflow guard)

    func testShapeContextCapsOlderToolResultsKeepsRecent() {
        let big = String(repeating: "x", count: 5000)
        let msgs = [
            ChatMessage(role: .user, content: "q"),
            ChatMessage(role: .tool, content: big, toolCallID: "1"),   // old → should cap
            ChatMessage(role: .tool, content: big, toolCallID: "2"),   // recent → keep
        ]
        let out = Orchestrator.shapeContext(msgs, maxToolResultChars: 100, keepRecentFull: 1)
        XCTAssertEqual(out[0].content, "q")                                   // non-tool untouched
        XCTAssertTrue(out[1].content.count < 200, "old tool result capped")
        XCTAssertTrue(out[1].content.contains("truncated"))
        XCTAssertEqual(out[2].content, big, "most recent tool result kept full")
    }

    func testShapeContextDisabledAndUndersizedAreNoOps() {
        let msgs = [ChatMessage(role: .tool, content: String(repeating: "y", count: 9000), toolCallID: "1")]
        XCTAssertEqual(Orchestrator.shapeContext(msgs, maxToolResultChars: 0, keepRecentFull: 0), msgs)  // disabled
        // Only 1 tool result and keepRecentFull 3 ⇒ nothing capped.
        XCTAssertEqual(Orchestrator.shapeContext(msgs, maxToolResultChars: 100, keepRecentFull: 3), msgs)
    }

    func testLoopAppliesShapingToModelInput() async throws {
        // Two rounds: a tool returns a huge result each round. With keepRecentFull 0 + small cap,
        // the SECOND model call must receive a truncated copy of the FIRST round's tool result.
        let huge = String(repeating: "z", count: 4000)
        let client = MockClient([
            Completion(content: nil, toolCalls: [ToolCall(id: "1", name: "s", arguments: #"{"n":1}"#)]),
            Completion(content: nil, toolCalls: [ToolCall(id: "2", name: "s", arguments: #"{"n":2}"#)]),
        ])
        let orch = Orchestrator(client: client, maxRounds: 2,
                                maxToolResultChars: 50, keepRecentToolResultsFull: 0)
        _ = try await orch.run(systemPrompt: "s", query: "q", tools: [tool("s", returns: huge)])
        // 2nd model call's messages: the first tool result (role .tool) must be truncated.
        let secondCall = client.sentMessages[1]
        let firstToolResult = secondCall.first { $0.role == .tool }
        XCTAssertNotNil(firstToolResult)
        XCTAssertTrue((firstToolResult?.content.count ?? 9999) < 200, "shaping should cap the old tool result sent to the model")
        XCTAssertTrue(firstToolResult?.content.contains("truncated") ?? false)
    }
}
