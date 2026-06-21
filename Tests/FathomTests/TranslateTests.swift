import XCTest
@testable import Fathom

final class TranslateTests: XCTestCase {

    func testSystemPromptNamesLanguageAndForbidsPreamble() {
        let p = Translation.systemPrompt(to: "中文")
        XCTAssertTrue(p.contains("中文"), "target language is named")
        XCTAssertTrue(p.lowercased().contains("only the translation"), "no-preamble instruction present")
    }

    func testTranslateToolUsesModelAndPrompt() async {
        let client = MockClient([Completion(content: "Bonjour le monde")])
        let tool = TranslateTool(client: client)
        let out = await tool.invoke(arguments: #"{"text":"Hello world","to":"French"}"#)
        XCTAssertEqual(out, "Bonjour le monde")
        // The model was sent the translation system prompt + the user text.
        let sent = client.sentMessages.last!
        XCTAssertTrue(sent.contains { $0.role == .system && $0.content.contains("French") })
        XCTAssertTrue(sent.contains { $0.role == .user && $0.content == "Hello world" })
    }

    func testTranslateToolMissingArgs() async {
        let tool = TranslateTool(client: MockClient([]))
        let out = await tool.invoke(arguments: #"{"text":"hi"}"#)
        XCTAssertTrue(out.contains("Missing"))
    }
}
