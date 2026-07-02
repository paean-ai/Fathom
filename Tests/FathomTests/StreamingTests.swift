import XCTest
@testable import Fathom

/// A scripted streaming client: each queued element is the list of deltas for one
/// `stream()` call, consumed in order. Also satisfies `complete` for the fallback path.
final class MockStreamingClient: StreamingLLMClient, @unchecked Sendable {
    private var streams: [[StreamDelta]]
    /// Scripted replies for non-streaming `complete` calls (the compaction summarizer uses
    /// them mid-stream); records what each was sent.
    private var completions: [Completion]
    private(set) var completeMessages: [[ChatMessage]] = []
    init(_ streams: [[StreamDelta]], completions: [Completion] = []) {
        self.streams = streams; self.completions = completions
    }

    func stream(messages: [ChatMessage], tools: [[String: Any]]) -> AsyncThrowingStream<StreamDelta, Error> {
        let deltas = streams.isEmpty ? [.text("done")] : streams.removeFirst()
        return AsyncThrowingStream { cont in
            for d in deltas { cont.yield(d) }
            cont.finish()
        }
    }
    func complete(messages: [ChatMessage], tools: [[String: Any]]) async throws -> Completion {
        completeMessages.append(messages)
        return completions.isEmpty ? Completion(content: "non-streaming fallback") : completions.removeFirst()
    }
}

final class StreamingTests: XCTestCase {

    private func collect(_ stream: AsyncThrowingStream<AgentEvent, Error>) async throws -> (deltas: [String], result: RunResult?) {
        var deltas: [String] = []; var result: RunResult?
        for try await ev in stream {
            switch ev {
            case .answerDelta(let t): deltas.append(t)
            case .finished(let r): result = r
            default: break
            }
        }
        return (deltas, result)
    }

    func testStreamsPlainAnswerInChunks() async throws {
        let client = MockStreamingClient([[.text("Hello, "), .text("world."), .usage(Usage(prompt: 5, completion: 3))]])
        let agent = Agent(client: client, systemPrompt: "assistant")
        let (deltas, result) = try await collect(agent.stream("hi"))
        XCTAssertEqual(deltas, ["Hello, ", "world."], "answer arrives as chunks")
        XCTAssertEqual(result?.answer, "Hello, world.")
        XCTAssertEqual(result?.finish, .natural)
        XCTAssertEqual(result?.usage.totalTokens, 8)
    }

    func testStreamsToolThenAnswer() async throws {
        // Round 1: the model streams a tool call (no text). Round 2: streams the answer.
        let client = MockStreamingClient([
            [.toolCall(ToolCall(id: "1", name: "search", arguments: #"{"q":"x"}"#))],
            [.text("Based on the search: 42.")],
        ])
        let tool = ClosureTool(name: "search", description: "s") { _ in "RESULT" }
        let orch = Orchestrator(client: client)

        var statuses: [String] = [], toolResults: [String] = [], deltas: [String] = []
        var result: RunResult?
        for try await ev in orch.runStreaming(systemPrompt: "s", query: "q", tools: [tool]) {
            switch ev {
            case .status(let s): statuses.append(s)
            case .toolResult(_, let r): toolResults.append(r)
            case .answerDelta(let t): deltas.append(t)
            case .reasoningDelta: break
            case .finished(let r): result = r
            }
        }
        XCTAssertEqual(toolResults, ["RESULT"], "the tool ran and its result surfaced")
        XCTAssertTrue(statuses.contains { $0.contains("search") })
        XCTAssertEqual(deltas, ["Based on the search: 42."])
        XCTAssertEqual(result?.toolCallCount, 1)
        XCTAssertEqual(result?.answer, "Based on the search: 42.")
    }

    func testFallsBackForNonStreamingClient() async throws {
        // MockClient (from OrchestratorTests) is not a StreamingLLMClient → whole-answer fallback.
        let client = MockClient([Completion(content: "one-shot answer")])
        let agent = Agent(client: client, systemPrompt: "assistant")
        let (deltas, result) = try await collect(agent.stream("hi"))
        XCTAssertEqual(deltas, ["one-shot answer"], "non-streaming client yields the whole answer once")
        XCTAssertEqual(result?.answer, "one-shot answer")
    }

    func testStreamingRunCompactsPastThreshold() async throws {
        // Round 1 reports a prompt over the threshold → round 2 opens by compacting
        // (a non-streaming summarize call), then the streamed answer completes as usual.
        let client = MockStreamingClient([
            [.toolCall(ToolCall(id: "1", name: "probe", arguments: "{}")),
             .usage(Usage(prompt: 150_000, completion: 5))],
            [.text("after "), .text("compaction")],
        ], completions: [Completion(content: "THE-BRIEF")])
        var history: [ChatMessage] = []
        for i in 0..<8 {
            history.append(ChatMessage(role: .user, content: "old q\(i)"))
            history.append(ChatMessage(role: .assistant, content: "old a\(i)"))
        }
        var orch = Orchestrator(client: client, compactionThresholdTokens: 100_000,
                                keepRecentOnCompaction: 2)
        orch.maxToolResultChars = 0
        let probe = ClosureTool(name: "probe", description: "p") { _ in "DATA" }
        var result: RunResult?
        for try await ev in orch.runStreaming(systemPrompt: "sys", query: "goal",
                                              history: history, tools: [probe]) {
            if case .finished(let r) = ev { result = r }
        }
        XCTAssertEqual(result?.answer, "after compaction")
        XCTAssertEqual(result?.compactions, 1)
        XCTAssertTrue(result?.messages.contains { $0.content.contains("CONTEXT RECAP") && $0.content.contains("THE-BRIEF") } == true)
        XCTAssertFalse(result?.messages.contains { $0.content == "old q3" } == true)
        // The summarizer (a complete call) saw the old turns.
        XCTAssertTrue(client.completeMessages.first?.last?.content.contains("old q3") == true)
    }
}
