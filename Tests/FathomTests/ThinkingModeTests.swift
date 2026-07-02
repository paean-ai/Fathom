import XCTest
@testable import Fathom

/// deepseek-v4 thinking mode: the request opts in via `thinking`/`reasoning_effort`, and a
/// tool-calling assistant turn must carry its `reasoning_content` back to the API verbatim
/// (the API 400s otherwise). All OFF by default.
final class ThinkingModeTests: XCTestCase {

    private let cfg = LLMConfig(apiKey: "k")

    // MARK: request body

    func testThinkingOffByDefault() {
        let body = DeepSeekClient(config: cfg).requestBody(messages: [], tools: [])
        XCTAssertNil(body["thinking"])
        XCTAssertNil(body["reasoning_effort"])
    }

    func testThinkingOnAddsFlagsToBody() {
        var c = cfg; c.thinking = true; c.reasoningEffort = "high"
        let body = DeepSeekClient(config: c).requestBody(messages: [], tools: [], stream: true)
        XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "enabled")
        XCTAssertEqual(body["reasoning_effort"] as? String, "high")
        XCTAssertEqual(body["stream"] as? Bool, true)
    }

    // MARK: wire round-trip

    func testWireCarriesReasoningContentOnToolCallTurns() {
        let turn = ChatMessage(role: .assistant, content: "",
                               toolCalls: [ToolCall(id: "1", name: "probe", arguments: "{}")],
                               reasoningContent: "I should probe first.")
        let d = DeepSeekClient.wire(turn)
        XCTAssertEqual(d["reasoning_content"] as? String, "I should probe first.")
    }

    func testWireOmitsReasoningContentOnPlainTurns() {
        // A non-tool assistant turn doesn't send reasoning back (the API ignores it at best).
        let turn = ChatMessage(role: .assistant, content: "answer", reasoningContent: "thoughts")
        XCTAssertNil(DeepSeekClient.wire(turn)["reasoning_content"])
    }

    // MARK: loop behavior

    func testOrchestratorCarriesReasoningAcrossToolRounds() async throws {
        let client = MockClient([
            Completion(content: nil,
                       toolCalls: [ToolCall(id: "1", name: "probe", arguments: "{}")],
                       reasoningContent: "let me probe"),
            Completion(content: "done"),
        ])
        let orch = Orchestrator(client: client)
        let probe = ClosureTool(name: "probe", description: "p") { _ in "DATA" }
        let result = try await orch.run(systemPrompt: "sys", query: "go", tools: [probe])
        let assistant = result.messages.first { !$0.toolCalls.isEmpty }
        XCTAssertEqual(assistant?.reasoningContent, "let me probe",
                       "the transcript must retain the CoT the API requires back")
        // Round 2's request actually contained that turn with its reasoning intact.
        let round2 = client.sentMessages.last
        XCTAssertTrue(round2?.contains { $0.reasoningContent == "let me probe" } == true)
    }

    func testStreamingAccumulatesReasoningOntoToolTurn() async throws {
        let client = MockStreamingClient([
            [.reasoning("think "), .reasoning("hard"),
             .toolCall(ToolCall(id: "1", name: "probe", arguments: "{}"))],
            [.text("done")],
        ])
        let orch = Orchestrator(client: client)
        let probe = ClosureTool(name: "probe", description: "p") { _ in "DATA" }
        var reasoningDeltas: [String] = []
        var result: RunResult?
        for try await ev in orch.runStreaming(systemPrompt: "sys", query: "go", tools: [probe]) {
            switch ev {
            case .reasoningDelta(let t): reasoningDeltas.append(t)
            case .finished(let r): result = r
            default: break
            }
        }
        XCTAssertEqual(reasoningDeltas, ["think ", "hard"], "reasoning surfaces for thinking-UI")
        let assistant = result?.messages.first { !$0.toolCalls.isEmpty }
        XCTAssertEqual(assistant?.reasoningContent, "think hard")
        XCTAssertEqual(result?.answer, "done")
    }
}
