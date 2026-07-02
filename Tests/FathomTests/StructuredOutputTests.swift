import XCTest
@testable import Fathom

/// Structured output: `runStructured` returns the final answer decoded as a Swift type,
/// with the guardrail machinery regenerating on malformed JSON.
final class StructuredOutputTests: XCTestCase {

    private struct Report: Decodable, Equatable {
        let title: String
        let count: Int
    }

    // MARK: extractJSON (pure)

    func testExtractJSONStripsCodeFence() {
        let fenced = "```json\n{\"a\": 1}\n```"
        XCTAssertEqual(Orchestrator.extractJSON(fenced), "{\"a\": 1}")
    }

    func testExtractJSONStripsSurroundingProse() {
        let chatty = "Sure! Here is the JSON you asked for:\n{\"title\": \"x\", \"count\": 2}\nHope that helps."
        XCTAssertEqual(Orchestrator.extractJSON(chatty), "{\"title\": \"x\", \"count\": 2}")
    }

    func testExtractJSONHandlesArraysAndScalars() {
        XCTAssertEqual(Orchestrator.extractJSON("the list: [1, 2, 3] as requested"), "[1, 2, 3]")
        XCTAssertEqual(Orchestrator.extractJSON("  42  "), "42")   // no delimiters → trimmed as-is
    }

    func testExtractJSONKeepsNestedBracesIntact() {
        let nested = #"{"outer": {"inner": [1, {"deep": true}]}}"#
        XCTAssertEqual(Orchestrator.extractJSON("x " + nested + " y"), nested)
    }

    // MARK: loop behavior

    func testRunStructuredDecodesToolAssistedAnswer() async throws {
        let client = MockClient([
            Completion(content: nil, toolCalls: [ToolCall(id: "1", name: "probe", arguments: "{}")]),
            Completion(content: #"{"title": "done", "count": 3}"#),
        ])
        let orch = Orchestrator(client: client)
        let probe = ClosureTool(name: "probe", description: "p") { _ in "DATA" }
        let (value, run) = try await orch.runStructured(Report.self,
                                                        systemPrompt: "sys", query: "build a report",
                                                        tools: [probe],
                                                        schemaHint: #"{"title": string, "count": int}"#)
        XCTAssertEqual(value, Report(title: "done", count: 3))
        XCTAssertEqual(run.guardrailRetries, 0)
        // The schema instruction reached the model.
        XCTAssertTrue(client.sentMessages.first?.first?.content.contains("OUTPUT FORMAT") == true)
    }

    func testRunStructuredRetriesOnMalformedThenDecodes() async throws {
        let client = MockClient([
            Completion(content: "Here's your report! It has three items."),   // prose, not JSON
            Completion(content: "```json\n{\"title\": \"ok\", \"count\": 1}\n```"),  // fenced but valid
        ])
        let orch = Orchestrator(client: client)
        let (value, run) = try await orch.runStructured(Report.self,
                                                        systemPrompt: "sys", query: "report",
                                                        schemaHint: #"{"title": string, "count": int}"#)
        XCTAssertEqual(value, Report(title: "ok", count: 1))
        XCTAssertEqual(run.guardrailRetries, 1)
    }

    func testRunStructuredThrowsWhenNeverDecodable() async {
        let client = MockClient(Array(repeating: Completion(content: "not json, ever"), count: 6))
        let orch = Orchestrator(client: client)
        do {
            _ = try await orch.runStructured(Report.self, systemPrompt: "sys", query: "report",
                                             schemaHint: "{}")
            XCTFail("should have thrown")
        } catch let e as StructuredOutputError {
            XCTAssertEqual(e.answer, "not json, ever")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testAgentConvenienceDecodes() async throws {
        let client = MockClient([Completion(content: #"{"title": "a", "count": 0}"#)])
        let agent = Agent(client: client, systemPrompt: "you report")
        let (value, _) = try await agent.runStructured(Report.self, query: "go",
                                                       schemaHint: #"{"title": string, "count": int}"#)
        XCTAssertEqual(value, Report(title: "a", count: 0))
    }
}
