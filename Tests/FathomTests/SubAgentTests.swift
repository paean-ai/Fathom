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

    // MARK: SubAgentRouterTool (dynamic specialist routing)

    func testRouterDescriptionEnumeratesSpecialistsAndConstrainsType() {
        let router = SubAgentRouterTool(specialists: [
            Specialist(type: "researcher", description: "Deep research", agent: Agent(client: MockClient([]), systemPrompt: "r")),
            Specialist(type: "coder", description: "Write code", agent: Agent(client: MockClient([]), systemPrompt: "c")),
        ])
        XCTAssertEqual(router.name, "spawn_subagent")
        XCTAssertTrue(router.isMutating)
        XCTAssertTrue(router.toolDescription.contains("researcher: Deep research"))
        XCTAssertTrue(router.toolDescription.contains("coder: Write code"))
        let props = router.parameters["properties"] as? [String: Any]
        let typeEnum = (props?["type"] as? [String: Any])?["enum"] as? [String]
        XCTAssertEqual(typeEnum, ["researcher", "coder"])   // order preserved, model constrained to the menu
    }

    func testRouterRoutesToTheChosenSpecialist() async {
        let researchClient = MockClient([Completion(content: "research findings")])
        let coderClient = MockClient([Completion(content: "code written")])
        let router = SubAgentRouterTool(specialists: [
            Specialist(type: "researcher", description: "Deep research", agent: Agent(client: researchClient, systemPrompt: "you research")),
            Specialist(type: "coder", description: "Write code", agent: Agent(client: coderClient, systemPrompt: "you code")),
        ])

        let out = await router.invoke(arguments: #"{"type":"coder","task":"implement the parser"}"#)
        XCTAssertEqual(out, "code written")
        // Only the coder ran; the researcher was never invoked.
        XCTAssertTrue(coderClient.sentMessages.last!.contains { $0.role == .user && $0.content == "implement the parser" })
        XCTAssertTrue(researchClient.sentMessages.isEmpty)
    }

    func testRouterUnknownTypeListsValidOptions() async {
        let router = SubAgentRouterTool(specialists: [
            Specialist(type: "researcher", description: "Deep research", agent: Agent(client: MockClient([]), systemPrompt: "r")),
        ])
        let out = await router.invoke(arguments: #"{"type":"wizard","task":"do magic"}"#)
        XCTAssertTrue(out.contains("Unknown specialist type 'wizard'"))
        XCTAssertTrue(out.contains("researcher"))
    }

    func testRouterMissingTask() async {
        let router = SubAgentRouterTool(specialists: [
            Specialist(type: "x", description: "y", agent: Agent(client: MockClient([]), systemPrompt: "s")),
        ])
        let out = await router.invoke(arguments: #"{"type":"x"}"#)
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
