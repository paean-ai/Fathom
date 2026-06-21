import XCTest
@testable import Fathom

final class GuardrailTests: XCTestCase {

    func testGuardrailPassesUnchanged() async throws {
        let client = MockClient([Completion(content: "a fine answer")])
        let orch = Orchestrator(client: client, outputGuardrail: { _ in .pass })
        let result = try await orch.run(systemPrompt: "s", query: "q", tools: [])
        XCTAssertEqual(result.answer, "a fine answer")
        XCTAssertEqual(result.guardrailRetries, 0)
    }

    func testGuardrailForcesOneRegeneration() async throws {
        // First answer fails the guardrail; the regenerated one passes.
        let client = MockClient([
            Completion(content: "missing the price"),       // ACT loop's natural answer
            Completion(content: "PRICE: $42 — corrected"),  // regenerated after guardrail retry
        ])
        let orch = Orchestrator(client: client, outputGuardrail: { ans in
            ans.contains("PRICE:") ? .pass : .retry("must include a PRICE: line")
        })
        let result = try await orch.run(systemPrompt: "s", query: "what's the price", tools: [])
        XCTAssertEqual(result.guardrailRetries, 1)
        XCTAssertEqual(result.answer, "PRICE: $42 — corrected")
    }

    func testGuardrailRetriesAreBounded() async throws {
        // The guardrail always fails; maxGuardrailRetries caps the regenerations.
        let client = MockClient(Array(repeating: Completion(content: "still bad"), count: 10))
        let orch = Orchestrator(client: client, outputGuardrail: { _ in .retry("nope") }, maxGuardrailRetries: 2)
        let result = try await orch.run(systemPrompt: "s", query: "q", tools: [])
        XCTAssertEqual(result.guardrailRetries, 2, "stops after maxGuardrailRetries")
    }

    func testGuardrailViaAgentEnforcesJSON() async throws {
        // A realistic use: require the answer to be valid JSON.
        let client = MockClient([
            Completion(content: "not json at all"),
            Completion(content: #"{"ok": true}"#),
        ])
        let agent = Agent(client: client, systemPrompt: "Answer in JSON.",
                          outputGuardrail: { s in
                              (try? JSONSerialization.jsonObject(with: Data(s.utf8))) != nil
                                  ? .pass : .retry("must be valid JSON")
                          })
        let result = try await agent.run("give me an object")
        XCTAssertEqual(result.answer, #"{"ok": true}"#)
        XCTAssertEqual(result.guardrailRetries, 1)
    }
}
