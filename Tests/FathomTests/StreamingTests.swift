import XCTest
@testable import Fathom

/// A scripted streaming client: each queued element is the list of deltas for one
/// `stream()` call, consumed in order. Also satisfies `complete` for the fallback path.
final class MockStreamingClient: StreamingLLMClient, @unchecked Sendable {
    private var streams: [[StreamDelta]]
    init(_ streams: [[StreamDelta]]) { self.streams = streams }

    func stream(messages: [ChatMessage], tools: [[String: Any]]) -> AsyncThrowingStream<StreamDelta, Error> {
        let deltas = streams.isEmpty ? [.text("done")] : streams.removeFirst()
        return AsyncThrowingStream { cont in
            for d in deltas { cont.yield(d) }
            cont.finish()
        }
    }
    func complete(messages: [ChatMessage], tools: [[String: Any]]) async throws -> Completion {
        Completion(content: "non-streaming fallback")
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
}
