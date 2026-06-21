import XCTest
@testable import Fathom

final class BudgetTests: XCTestCase {

    // MARK: usage tracking

    func testUsageAccumulatesAcrossCalls() async throws {
        let client = MockClient([
            Completion(content: nil, toolCalls: [ToolCall(id: "1", name: "t", arguments: "{}")],
                       usage: Usage(prompt: 30, completion: 10)),
            Completion(content: "done", usage: Usage(prompt: 12, completion: 8)),
        ])
        let tool = ClosureTool(name: "t", description: "x") { _ in "R" }
        let result = try await Orchestrator(client: client).run(systemPrompt: "s", query: "q", tools: [tool])
        XCTAssertEqual(result.usage.totalTokens, 60, "30+10 + 12+8")
        XCTAssertEqual(result.usage.promptTokens, 42)
    }

    func testUsageParsedFromWireResponse() throws {
        let json = #"""
        {"choices":[{"message":{"content":"hi"}}],
         "usage":{"prompt_tokens":11,"completion_tokens":7,"total_tokens":18}}
        """#
        let c = try DeepSeekClient.parseCompletion(Data(json.utf8))
        XCTAssertEqual(c.usage, Usage(prompt: 11, completion: 7, total: 18))
        XCTAssertEqual(c.content, "hi")
    }

    // MARK: token budget

    func testTokenBudgetStopsTheLoop() async throws {
        // One round costs 100 tokens; budget is 50 → after one round the loop stops, and
        // the closing tool-free call produces the final answer.
        let client = MockClient([
            Completion(content: nil, toolCalls: [ToolCall(id: "1", name: "t", arguments: #"{"n":1}"#)],
                       usage: Usage(prompt: 80, completion: 20)),
            Completion(content: "forced final answer"),   // the closing tool-free call
        ])
        let tool = ClosureTool(name: "t", description: "x") { _ in "R" }
        let orch = Orchestrator(client: client, maxRounds: 10, tokenBudget: 50)
        let result = try await orch.run(systemPrompt: "s", query: "q", tools: [tool])
        XCTAssertEqual(result.finish, .budget, "the budget cap ended the loop")
        XCTAssertEqual(result.answer, "forced final answer")
        XCTAssertEqual(result.toolCallCount, 1, "only one round ran before the budget bit")
    }

    func testNoBudgetIsUnbounded() async throws {
        let client = MockClient([
            Completion(content: nil, toolCalls: [ToolCall(id: "1", name: "t", arguments: "{}")], usage: Usage(prompt: 999)),
            Completion(content: "answer"),
        ])
        let tool = ClosureTool(name: "t", description: "x") { _ in "R" }
        let result = try await Orchestrator(client: client).run(systemPrompt: "s", query: "q", tools: [tool])
        XCTAssertEqual(result.finish, .natural, "no budget → runs to a natural finish")
    }

    // MARK: cancellation

    func testCancellationStopsGracefully() async throws {
        let client = MockClient([
            Completion(content: nil, toolCalls: [ToolCall(id: "1", name: "t", arguments: "{}")]),
            Completion(content: "should not reach"),
        ])
        let tool = ClosureTool(name: "t", description: "x") { _ in "R" }
        let orch = Orchestrator(client: client)
        let task = Task { try await orch.run(systemPrompt: "s", query: "q", tools: [tool]) }
        task.cancel()   // cancelled before the loop's first check runs
        let result = try await task.value
        XCTAssertEqual(result.finish, .cancelled)
        XCTAssertEqual(result.toolCallCount, 0, "nothing executed after cancellation")
    }
}
