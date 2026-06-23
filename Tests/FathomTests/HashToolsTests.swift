import XCTest
@testable import Fathom

final class HashToolsTests: XCTestCase {

    func testSHA256KnownVectors() {
        // Standard SHA-256 test vectors.
        XCTAssertEqual(Hashing.sha256Hex(""),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(Hashing.sha256Hex("abc"),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(Hashing.short("abc"), "ba7816bf8f01")
    }

    func testHTMLEntities() {
        XCTAssertEqual(HTMLEntities.escape("<a href=\"x\">A&B</a>"),
                       "&lt;a href=&quot;x&quot;&gt;A&amp;B&lt;/a&gt;")
        // Round-trip.
        let s = "Tom & Jerry's <tag>"
        XCTAssertEqual(HTMLEntities.unescape(HTMLEntities.escape(s)), s)
    }

    func testToolsInvoke() async {
        let h = await HashTool().invoke(arguments: #"{"text":"abc"}"#)
        XCTAssertTrue(h.contains("ba7816bf8f01cfea"))
        XCTAssertTrue(h.contains("Short: ba7816bf8f01"))
        let esc = await HTMLEntitiesTool().invoke(arguments: #"{"text":"a<b>"}"#)
        XCTAssertEqual(esc, "a&lt;b&gt;")
    }

    func testBundleNames() {
        XCTAssertEqual(Set(HashTools.all().map(\.name)), ["hash_text", "html_entities"])
    }
}
