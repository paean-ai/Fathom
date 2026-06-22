import XCTest
@testable import Fathom

/// Covers DeepSeek-native fields recovered by `DeepSeekClient.parseCompletion`:
/// `reasoning_content` and the context-cache token counters.
final class ParseCompletionTests: XCTestCase {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    func testParsesReasoningContent() throws {
        let body = data("""
        {"choices":[{"message":{"role":"assistant","content":"42","reasoning_content":"add the numbers"}}]}
        """)
        let c = try DeepSeekClient.parseCompletion(body)
        XCTAssertEqual(c.content, "42")
        XCTAssertEqual(c.reasoningContent, "add the numbers")
    }

    func testReasoningAbsentOrEmptyIsNil() throws {
        let plain = try DeepSeekClient.parseCompletion(data(#"{"choices":[{"message":{"content":"hi"}}]}"#))
        XCTAssertNil(plain.reasoningContent)
        let blank = try DeepSeekClient.parseCompletion(data(#"{"choices":[{"message":{"content":"hi","reasoning_content":""}}]}"#))
        XCTAssertNil(blank.reasoningContent)
    }

    func testParsesCacheTokenCounters() throws {
        let body = data("""
        {"choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":2048,"completion_tokens":12,"prompt_cache_hit_tokens":1920,"prompt_cache_miss_tokens":128}}
        """)
        let c = try DeepSeekClient.parseCompletion(body)
        XCTAssertEqual(c.usage?.cacheHitTokens, 1920)
        XCTAssertEqual(c.usage?.cacheMissTokens, 128)
        XCTAssertEqual(c.usage?.cacheHitRate ?? 0, 1920.0 / 2048.0, accuracy: 1e-9)
    }

    func testUsageWithoutCacheFieldsDefaultsToZero() throws {
        let body = data(#"{"choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":10,"completion_tokens":5}}"#)
        let c = try DeepSeekClient.parseCompletion(body)
        XCTAssertEqual(c.usage?.cacheHitTokens, 0)
        XCTAssertNil(c.usage?.cacheHitRate)
    }

    func testUsageAdditionSumsCacheCounters() {
        let a = Usage(prompt: 100, completion: 10, cacheHit: 80, cacheMiss: 20)
        let b = Usage(prompt: 50, completion: 5, cacheHit: 40, cacheMiss: 10)
        let sum = a + b
        XCTAssertEqual(sum.cacheHitTokens, 120)
        XCTAssertEqual(sum.cacheMissTokens, 30)
    }
}
