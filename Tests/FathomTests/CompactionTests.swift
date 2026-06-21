import XCTest
@testable import Fathom

final class CompactionTests: XCTestCase {

    // MARK: pure helpers

    func testEstimateAndPartition() {
        let msgs = [
            ChatMessage(role: .user, content: "aaaa"),       // 4
            ChatMessage(role: .assistant, content: "bb"),    // 2
            ChatMessage(role: .user, content: "cccccc"),     // 6
            ChatMessage(role: .assistant, content: "dd"),    // 2
        ]
        XCTAssertEqual(Thread.estimateChars(msgs), 14)

        let (old, keep) = Thread.partition(msgs, keepRecent: 2)
        XCTAssertEqual(old.map(\.content), ["aaaa", "bb"])
        XCTAssertEqual(keep.map(\.content), ["cccccc", "dd"])

        // Fewer than keepRecent → nothing to summarize.
        let (none, all) = Thread.partition(Array(msgs.prefix(2)), keepRecent: 2)
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(all.count, 2)
    }

    // MARK: integration

    func testThreadCompactsWhenOverLimit() async throws {
        // send 1 → answer one (2 msgs, not over keepRecent=2, no compaction).
        // send 2 → answer two (4 msgs) → compaction summarizes the first exchange.
        let client = MockClient([
            Completion(content: "answer one"),
            Completion(content: "answer two"),
            Completion(content: "SUMMARY: discussed q1 and got answer one"),
        ])
        let agent = Agent(client: client, systemPrompt: "assistant")
        let thread = agent.thread(contextLimit: 1, keepRecent: 2)   // tiny limit → always compacts past keepRecent

        _ = try await thread.send("q1")
        XCTAssertEqual(thread.compactions, 0, "only 2 messages — at keepRecent, nothing older to summarize")

        _ = try await thread.send("q2")
        XCTAssertEqual(thread.compactions, 1, "the older exchange was summarized")

        let msgs = thread.messages
        XCTAssertEqual(msgs.count, 3, "summary + the kept recent pair (q2 / answer two)")
        XCTAssertEqual(msgs.first?.role, .system)
        XCTAssertTrue(msgs.first!.content.contains("SUMMARY: discussed q1"), "rolling summary kept")
        XCTAssertEqual(msgs.last?.content, "answer two", "recent tail kept verbatim")
    }

    func testNoCompactionWithoutLimit() async throws {
        let client = MockClient([Completion(content: "a1"), Completion(content: "a2"), Completion(content: "a3")])
        let thread = Agent(client: client, systemPrompt: "s").thread()   // no contextLimit
        for q in ["q1", "q2", "q3"] { _ = try await thread.send(q) }
        XCTAssertEqual(thread.compactions, 0)
        XCTAssertEqual(thread.messages.count, 6, "full transcript retained")
    }
}
