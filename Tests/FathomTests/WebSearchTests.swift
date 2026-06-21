import XCTest
@testable import Fathom

/// A scripted web engine for testing the web tools without a network.
struct MockEngine: WebSearchEngine {
    let results: [WebResult]
    let pages: [String: String]
    func search(_ query: String, limit: Int) async -> [WebResult] { Array(results.prefix(limit)) }
    func fetch(_ url: String) async -> String? { pages[url] }
}

final class WebSearchTests: XCTestCase {

    func testWebSearchToolFormatsResults() async {
        let engine = MockEngine(results: [
            WebResult(title: "Swift", url: "https://swift.org", snippet: "A language."),
            WebResult(title: "Docs", url: "https://swift.org/docs", snippet: "Guides."),
        ], pages: [:])
        let out = await WebSearchTool(engine: engine).invoke(arguments: #"{"query":"swift"}"#)
        XCTAssertTrue(out.contains("[1] Swift"))
        XCTAssertTrue(out.contains("https://swift.org/docs"))
    }

    func testWebSearchToolEmptyAndMissing() async {
        let empty = MockEngine(results: [], pages: [:])
        let none = await WebSearchTool(engine: empty).invoke(arguments: #"{"query":"x"}"#)
        XCTAssertTrue(none.contains("No web results"))
        let missing = await WebSearchTool(engine: empty).invoke(arguments: "{}")
        XCTAssertTrue(missing.contains("Missing"))
    }

    func testWebFetchToolReadsPage() async {
        let engine = MockEngine(results: [], pages: ["https://swift.org": "Readable body text."])
        let out = await WebFetchTool(engine: engine).invoke(arguments: #"{"url":"https://swift.org"}"#)
        XCTAssertEqual(out, "Readable body text.")
        let miss = await WebFetchTool(engine: engine).invoke(arguments: #"{"url":"https://nope.test"}"#)
        XCTAssertTrue(miss.contains("Couldn't read"))
    }
}
