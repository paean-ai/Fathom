import XCTest
@testable import Fathom

/// IN-RUN compaction: a single long tool loop summarizes its own middle and continues,
/// instead of overflowing the context window (distinct from `Thread`'s between-turn compaction).
final class InRunCompactionTests: XCTestCase {

    private func msg(_ role: Role, _ content: String, callID: String? = nil) -> ChatMessage {
        ChatMessage(role: role, content: content, toolCallID: callID)
    }

    // MARK: pure helpers

    func testCompactionSplitKeepsSystemAndGoalVerbatim() {
        let messages: [ChatMessage] = [
            msg(.system, "sys"), msg(.user, "the goal"),
            msg(.assistant, "a1"), msg(.tool, "t1", callID: "1"),
            msg(.assistant, "a2"), msg(.tool, "t2", callID: "2"),
            msg(.assistant, "a3"), msg(.tool, "t3", callID: "3"),
        ]
        let split = Orchestrator.compactionSplit(messages, keepRecent: 2)
        XCTAssertEqual(split.head.map(\.content), ["sys", "the goal"])
        XCTAssertEqual(split.middle.map(\.content), ["a1", "t1", "a2", "t2"])
        XCTAssertEqual(split.tail.map(\.content), ["a3", "t3"])
    }

    func testCompactionSplitNeverOrphansAToolResult() {
        // keepRecent: 1 would start the tail at a .tool message — the split must walk back
        // to include the assistant turn that issued the call.
        let messages: [ChatMessage] = [
            msg(.system, "sys"), msg(.user, "goal"),
            msg(.assistant, "a1"), msg(.tool, "t1", callID: "1"),
            msg(.assistant, "a2"), msg(.tool, "t2a", callID: "2"), msg(.tool, "t2b", callID: "3"),
        ]
        let split = Orchestrator.compactionSplit(messages, keepRecent: 2)
        XCTAssertEqual(split.tail.first?.content, "a2", "tail must start at the calling assistant turn")
        XCTAssertEqual(split.tail.map(\.content), ["a2", "t2a", "t2b"])
        XCTAssertEqual(split.middle.map(\.content), ["a1", "t1"])
    }

    func testCompactionSplitNoMiddleWhenSmall() {
        let messages: [ChatMessage] = [msg(.system, "sys"), msg(.user, "goal"), msg(.assistant, "a")]
        let split = Orchestrator.compactionSplit(messages, keepRecent: 6)
        XCTAssertTrue(split.middle.isEmpty)
        XCTAssertEqual(split.head.count + split.tail.count, 3)
    }

    func testEstimateTokensCountsContentAndToolCallArguments() {
        let plain = ChatMessage(role: .user, content: String(repeating: "x", count: 400))
        let calling = ChatMessage(role: .assistant, content: "",
                                  toolCalls: [ToolCall(id: "1", name: "run", arguments: String(repeating: "y", count: 397))])
        XCTAssertEqual(Orchestrator.estimateTokens([plain]), 108)     // 400/4 + 8
        XCTAssertEqual(Orchestrator.estimateTokens([calling]), 108)   // (0 + 3 + 397)/4 + 8
    }

    func testRenderForSummaryCapsHugeMessages() {
        let huge = ChatMessage(role: .tool, content: String(repeating: "z", count: 50_000), toolCallID: "1")
        let text = Orchestrator.renderForSummary([huge], perMessageCap: 100)
        XCTAssertLessThan(text.count, 200)
        XCTAssertTrue(text.hasPrefix("tool: zzz"))
    }

    // MARK: loop behavior

    /// Long history + a reported prompt size over the threshold → the next round compacts:
    /// the summarizer is consulted, the middle collapses into one recap, and the run finishes.
    func testLoopCompactsWhenReportedPromptExceedsThreshold() async throws {
        var history: [ChatMessage] = []
        for i in 0..<8 {
            history.append(msg(.user, "old question \(i)"))
            history.append(msg(.assistant, "old answer \(i)"))
        }
        let client = MockClient([
            // Round 1: a tool call whose reported prompt size is over the threshold.
            Completion(content: nil,
                       toolCalls: [ToolCall(id: "1", name: "probe", arguments: #"{"q":"x"}"#)],
                       usage: Usage(prompt: 150_000, completion: 10)),
            // Round 2 opens with the compaction summarize call…
            Completion(content: "THE-BRIEF"),
            // …then the model answers.
            Completion(content: "final answer"),
        ])
        var orch = Orchestrator(client: client, compactionThresholdTokens: 100_000, keepRecentOnCompaction: 2)
        orch.maxToolResultChars = 0   // isolate compaction from tool-result shaping
        let probe = ClosureTool(name: "probe", description: "p") { _ in "PROBE-RESULT" }
        let result = try await orch.run(systemPrompt: "sys", query: "the goal",
                                        history: history, tools: [probe])

        XCTAssertEqual(result.answer, "final answer")
        XCTAssertEqual(result.compactions, 1)
        // The summarizer saw the old turns rendered as a transcript.
        let summarizeCall = client.sentMessages.first { $0.first?.content.hasPrefix("You compress") == true }
        XCTAssertNotNil(summarizeCall)
        XCTAssertTrue(summarizeCall?.last?.content.contains("old question 3") == true)
        // The final transcript carries the recap instead of the old turns.
        XCTAssertTrue(result.messages.contains { $0.content.contains("CONTEXT RECAP") && $0.content.contains("THE-BRIEF") })
        XCTAssertFalse(result.messages.contains { $0.content == "old question 3" })
        // Head stayed verbatim: system prompt first, goal right after.
        XCTAssertEqual(result.messages.first?.content, "sys")
        XCTAssertEqual(result.messages.dropFirst().first?.content, "old question 0")
    }

    /// No reported usage at all → the char estimate alone triggers compaction.
    func testEstimateAloneTriggersCompaction() async throws {
        var history: [ChatMessage] = []
        for i in 0..<6 {
            history.append(msg(.user, "q\(i) " + String(repeating: "a", count: 2_000)))
            history.append(msg(.assistant, "ans\(i) " + String(repeating: "b", count: 2_000)))
        }
        let client = MockClient([
            Completion(content: "SUMMARY"),        // compaction fires before the FIRST model round
            Completion(content: "done directly"),  // then the model answers
        ])
        let orch = Orchestrator(client: client, compactionThresholdTokens: 1_000, keepRecentOnCompaction: 2)
        let result = try await orch.run(systemPrompt: "sys", query: "goal", history: history, tools: [])
        XCTAssertEqual(result.compactions, 1)
        XCTAssertEqual(result.answer, "done directly")
        XCTAssertTrue(result.messages.contains { $0.content.contains("SUMMARY") })
    }

    /// FAILURE-SAFE: an empty summary must leave the transcript untouched and never kill the run.
    func testEmptySummaryLeavesTranscriptUntouched() async throws {
        var history: [ChatMessage] = []
        for i in 0..<6 {
            history.append(msg(.user, "q\(i) " + String(repeating: "a", count: 2_000)))
            history.append(msg(.assistant, "ans\(i) " + String(repeating: "b", count: 2_000)))
        }
        let client = MockClient([
            Completion(content: "   "),   // the summarizer returns nothing usable
            Completion(content: "still answered"),
        ])
        let orch = Orchestrator(client: client, compactionThresholdTokens: 1_000, keepRecentOnCompaction: 2)
        let result = try await orch.run(systemPrompt: "sys", query: "goal", history: history, tools: [])
        XCTAssertEqual(result.compactions, 0)
        XCTAssertEqual(result.answer, "still answered")
        XCTAssertTrue(result.messages.contains { $0.content.hasPrefix("q3") })
    }

    /// Off by default: no threshold → no summarizer call, however big the transcript.
    func testDisabledByDefault() async throws {
        let history = (0..<6).flatMap { i -> [ChatMessage] in
            [msg(.user, String(repeating: "a", count: 5_000)), msg(.assistant, "ans\(i)")]
        }
        let client = MockClient([Completion(content: "plain")])
        let orch = Orchestrator(client: client)
        let result = try await orch.run(systemPrompt: "sys", query: "goal", history: history, tools: [])
        XCTAssertEqual(result.compactions, 0)
        XCTAssertEqual(client.sentMessages.count, 1)
    }
}
