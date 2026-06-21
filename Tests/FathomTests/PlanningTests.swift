import XCTest
@testable import Fathom

final class PlanningTests: XCTestCase {

    // MARK: pure parsers

    func testParsePlanStepsDropsPreambleAndDedupes() {
        let steps = Orchestrator.parsePlanSteps("""
        Sure, here's the plan:
        1. search the knowledge base
        2. Search the knowledge base
        3. summarize the findings
        Let me begin!
        """)
        XCTAssertEqual(steps, ["search the knowledge base", "summarize the findings"],
                       "preamble/closing dropped; case-insensitive duplicate collapsed")
    }

    func testParseCriticVerdicts() {
        XCTAssertEqual(Orchestrator.parseCritic("PASS"), .pass)
        XCTAssertEqual(Orchestrator.parseCritic("  ok  "), .pass)
        XCTAssertEqual(Orchestrator.parseCritic("REVISE: cite the source for claim 2"),
                       .revise("cite the source for claim 2"))
        XCTAssertEqual(Orchestrator.parseCritic("REVISE"), .revise("the answer needs to be more complete"))
        XCTAssertEqual(Orchestrator.parseCritic("some unrelated chatter"), .pass, "ambiguous defaults to pass")
    }

    // MARK: PLAN phase

    func testPlanningDecomposesAndReportsSteps() async throws {
        let client = MockClient([
            Completion(content: "1. find the files\n2. summarize them"),   // planner reply
            Completion(content: "Here is the summary."),                    // answer (no tools)
        ])
        let orch = Orchestrator(client: client, planning: true)
        let result = try await orch.run(systemPrompt: "assistant", query: "summarize my files", tools: [])

        XCTAssertEqual(result.plan, ["find the files", "summarize them"], "the goal was decomposed")
        XCTAssertEqual(result.answer, "Here is the summary.")
        // The plan was injected as guidance for the ACT loop.
        let actCall = client.sentMessages.last!
        XCTAssertTrue(actCall.contains { $0.role == .system && $0.content.contains("PLAN") },
                      "the plan is given to the loop")
    }

    // MARK: VERIFY phase

    func testCriticTriggersOneRevision() async throws {
        let client = MockClient([
            Completion(content: "A thin first draft."),     // ACT answer (no tools → natural)
            Completion(content: "REVISE: add specifics"),    // critic verdict
            Completion(content: "A thorough, specific answer."),  // revised answer
        ])
        let orch = Orchestrator(client: client, critic: true)
        let result = try await orch.run(systemPrompt: "assistant", query: "explain X", tools: [])

        XCTAssertTrue(result.revised, "the critic forced a revision")
        XCTAssertEqual(result.answer, "A thorough, specific answer.")
    }

    func testCriticPassKeepsAnswer() async throws {
        let client = MockClient([
            Completion(content: "A solid answer."),   // ACT answer
            Completion(content: "PASS"),              // critic approves
        ])
        let orch = Orchestrator(client: client, critic: true)
        let result = try await orch.run(systemPrompt: "assistant", query: "explain X", tools: [])

        XCTAssertFalse(result.revised, "a passing answer is not changed")
        XCTAssertEqual(result.answer, "A solid answer.")
    }

    func testPlanningAndCriticOffByDefault() async throws {
        let client = MockClient([Completion(content: "Direct answer.")])
        let result = try await Orchestrator(client: client).run(systemPrompt: "a", query: "q", tools: [])
        XCTAssertTrue(result.plan.isEmpty)
        XCTAssertFalse(result.revised)
        XCTAssertEqual(result.answer, "Direct answer.")
    }
}
