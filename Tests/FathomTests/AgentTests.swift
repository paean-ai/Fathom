import XCTest
@testable import Fathom

/// A client that throws for the first `failures` calls, then behaves like MockClient.
final class FlakyClient: LLMClient, @unchecked Sendable {
    struct Boom: Error {}
    private let lock = NSLock()
    private var remainingFailures: Int
    private var _attempts = 0
    private let answer: Completion
    init(failures: Int, then answer: Completion = Completion(content: "ok")) {
        self.remainingFailures = failures; self.answer = answer
    }
    var attempts: Int { lock.lock(); defer { lock.unlock() }; return _attempts }
    /// Synchronous step: record the attempt and decide whether to fail.
    private func nextShouldFail() -> Bool {
        lock.lock(); defer { lock.unlock() }
        _attempts += 1
        if remainingFailures > 0 { remainingFailures -= 1; return true }
        return false
    }
    func complete(messages: [ChatMessage], tools: [[String: Any]]) async throws -> Completion {
        if nextShouldFail() { throw Boom() }
        return answer
    }
}

final class AgentTests: XCTestCase {

    // MARK: human-in-the-loop approval

    func testDeniedMutatingToolIsNotExecuted() async throws {
        let client = MockClient([
            Completion(content: nil, toolCalls: [ToolCall(id: "1", name: "delete_all", arguments: "{}")]),
            Completion(content: "Okay, I won't delete anything."),
        ])
        let ran = Counter()
        let destructive = ClosureTool(name: "delete_all", description: "danger", isMutating: true) { _ in
            ran.bump(); return "DELETED EVERYTHING"
        }
        let orch = Orchestrator(client: client, approval: { _ in .deny("user said no") })
        let result = try await orch.run(systemPrompt: "s", query: "delete everything", tools: [destructive])

        XCTAssertEqual(ran.value, 0, "a denied mutating tool must NOT run")
        XCTAssertEqual(result.toolCallCount, 0, "nothing executed")
        XCTAssertTrue(result.messages.contains { $0.role == .tool && $0.content.contains("declined") },
                      "the denial is fed back to the model")
        XCTAssertEqual(result.answer, "Okay, I won't delete anything.")
    }

    func testApprovedMutatingToolRuns() async throws {
        let client = MockClient([
            Completion(content: nil, toolCalls: [ToolCall(id: "1", name: "tag", arguments: "{}")]),
            Completion(content: "Tagged."),
        ])
        let ran = Counter()
        let tool = ClosureTool(name: "tag", description: "x", isMutating: true) { _ in ran.bump(); return "OK" }
        let orch = Orchestrator(client: client, approval: { _ in .allow })
        _ = try await orch.run(systemPrompt: "s", query: "tag it", tools: [tool])
        XCTAssertEqual(ran.value, 1, "approved mutation runs")
    }

    func testNonMutatingToolsBypassApproval() async throws {
        let client = MockClient([
            Completion(content: nil, toolCalls: [ToolCall(id: "1", name: "search", arguments: "{}")]),
            Completion(content: "Found it."),
        ])
        let asked = Counter()
        let search = ClosureTool(name: "search", description: "x", isMutating: false) { _ in "R" }
        let orch = Orchestrator(client: client, approval: { _ in asked.bump(); return .deny("no") })
        _ = try await orch.run(systemPrompt: "s", query: "find", tools: [search])
        XCTAssertEqual(asked.value, 0, "read-only tools are never gated by approval")
    }

    // MARK: parallel tool execution

    func testMultipleToolCallsInOneRoundAllExecute() async throws {
        let client = MockClient([
            Completion(content: nil, toolCalls: [
                ToolCall(id: "a", name: "alpha", arguments: "{}"),
                ToolCall(id: "b", name: "beta", arguments: "{}"),
            ]),
            Completion(content: "Combined."),
        ])
        let a = ClosureTool(name: "alpha", description: "x") { _ in "RA" }
        let b = ClosureTool(name: "beta", description: "x") { _ in "RB" }
        let result = try await Orchestrator(client: client).run(systemPrompt: "s", query: "both", tools: [a, b])

        XCTAssertEqual(result.toolCallCount, 2)
        // Both results are threaded back, in the model's original call order.
        let toolMsgs = result.messages.filter { $0.role == .tool }.map(\.content)
        XCTAssertEqual(toolMsgs, ["RA", "RB"], "both ran; transcript order matches the call order")
    }

    // MARK: Agent + Thread (multi-turn memory)

    func testThreadRemembersPriorTurns() async throws {
        let client = MockClient([
            Completion(content: "First answer."),
            Completion(content: "Second answer."),
        ])
        let agent = Agent(client: client, systemPrompt: "assistant")
        let thread = agent.thread()

        let r1 = try await thread.send("first question")
        XCTAssertEqual(r1.answer, "First answer.")

        let r2 = try await thread.send("second question")
        XCTAssertEqual(r2.answer, "Second answer.")

        // The transcript holds both exchanges…
        XCTAssertEqual(thread.messages.map(\.content),
                       ["first question", "First answer.", "second question", "Second answer."])
        // …and the SECOND model call was given the first exchange as history.
        let secondCallContents = client.sentMessages.last!.map(\.content)
        XCTAssertTrue(secondCallContents.contains("first question"))
        XCTAssertTrue(secondCallContents.contains("First answer."))

        thread.reset()
        XCTAssertTrue(thread.messages.isEmpty, "reset clears memory")
    }

    // MARK: RetryingClient (resilience)

    func testRetryingClientRecoversAfterTransientFailures() async throws {
        let flaky = FlakyClient(failures: 2, then: Completion(content: "recovered"))
        let client = RetryingClient(wrapping: flaky, maxAttempts: 3, backoff: { _ in })  // no sleep in tests
        let completion = try await client.complete(messages: [], tools: [])
        XCTAssertEqual(completion.content, "recovered")
        XCTAssertEqual(flaky.attempts, 3, "two failures + one success")
    }

    func testRetryingClientGivesUpAfterMaxAttempts() async {
        let flaky = FlakyClient(failures: 5)
        let client = RetryingClient(wrapping: flaky, maxAttempts: 3, backoff: { _ in })
        do {
            _ = try await client.complete(messages: [], tools: [])
            XCTFail("should have thrown after exhausting attempts")
        } catch {
            XCTAssertEqual(flaky.attempts, 3, "tried exactly maxAttempts times")
        }
    }

    func testRetryingClientSkipsNonRetryableErrors() async {
        let flaky = FlakyClient(failures: 5)
        let client = RetryingClient(wrapping: flaky, maxAttempts: 5,
                                    isRetryable: { _ in false }, backoff: { _ in })
        do {
            _ = try await client.complete(messages: [], tools: [])
            XCTFail("should have thrown")
        } catch {
            XCTAssertEqual(flaky.attempts, 1, "a non-retryable error is not retried")
        }
    }
}
