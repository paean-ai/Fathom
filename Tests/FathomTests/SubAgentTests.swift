import XCTest
@testable import Fathom

final class SubAgentTests: XCTestCase {

    func testSubAgentToolDelegatesAndReturnsAnswer() async {
        let subClient = MockClient([Completion(content: "the specialist's answer")])
        let specialist = Agent(client: subClient, systemPrompt: "You are a specialist.")
        let tool = SubAgentTool(name: "research", description: "Delegate research", agent: specialist)

        let out = await tool.invoke(arguments: #"{"task":"investigate vector search"}"#)
        XCTAssertEqual(out, "the specialist's answer")
        // The sub-agent received the delegated task as the user turn.
        let sent = subClient.sentMessages.last!
        XCTAssertTrue(sent.contains { $0.role == .user && $0.content == "investigate vector search" })
        XCTAssertTrue(sent.contains { $0.role == .system && $0.content.contains("specialist") })
    }

    func testSubAgentToolMissingTask() async {
        let tool = SubAgentTool(name: "x", description: "y", agent: Agent(client: MockClient([]), systemPrompt: "s"))
        let out = await tool.invoke(arguments: "{}")
        XCTAssertTrue(out.contains("Missing"))
    }

    func testParentDelegatesToSubAgentInLoop() async throws {
        // Sub-agent answers directly.
        let subClient = MockClient([Completion(content: "delegated result")])
        let sub = Agent(client: subClient, systemPrompt: "specialist")
        let delegate = SubAgentTool(name: "delegate", description: "hand off a task", agent: sub)

        // Parent calls the delegate tool, then answers using its result.
        let parentClient = MockClient([
            Completion(content: nil, toolCalls: [ToolCall(id: "1", name: "delegate", arguments: #"{"task":"do the thing"}"#)]),
            Completion(content: "Final: delegated result incorporated."),
        ])
        let lead = Agent(client: parentClient, systemPrompt: "coordinator", tools: [delegate])

        let result = try await lead.run("handle this")
        XCTAssertEqual(result.toolCallCount, 1, "the parent delegated once")
        XCTAssertTrue(result.messages.contains { $0.role == .tool && $0.content == "delegated result" },
                      "the sub-agent's answer was threaded back into the parent's transcript")
        XCTAssertEqual(result.answer, "Final: delegated result incorporated.")
    }
}
