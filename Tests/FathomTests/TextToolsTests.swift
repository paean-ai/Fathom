import XCTest
@testable import Fathom

final class TextToolsTests: XCTestCase {

    func testTransforms() {
        XCTAssertEqual(TextTransform.transform("Hello World", mode: "upper"), "HELLO WORLD")
        XCTAssertEqual(TextTransform.transform("Hello World", mode: "lower"), "hello world")
        XCTAssertEqual(TextTransform.transform("hello world", mode: "title"), "Hello World")
        XCTAssertEqual(TextTransform.transform("Hello World", mode: "kebab"), "hello-world")
        XCTAssertEqual(TextTransform.transform("Hello World", mode: "snake"), "hello_world")
        XCTAssertEqual(TextTransform.transform("abc", mode: "reverse"), "cba")
    }

    func testSlug() {
        XCTAssertEqual(TextTransform.slug("My Great Note!"), "my-great-note")
        XCTAssertEqual(TextTransform.slug("  spaced  out  "), "spaced-out")
    }

    func testBase64RoundTrip() {
        let enc = Base64.encode("hello")
        XCTAssertEqual(enc, "aGVsbG8=")
        XCTAssertEqual(Base64.decode(enc), "hello")
        XCTAssertNil(Base64.decode("!!!not base64!!!"))   // not decodable
        XCTAssertNil(Base64.decode("////"))               // valid base64 but not UTF-8
        let unicode = "café — naïve 🚀"                    // round-trips, embedded whitespace tolerated
        XCTAssertEqual(Base64.decode(Base64.encode(unicode)), unicode)
    }

    func testToolsInvoke() async {
        let t = await TextTransformTool().invoke(arguments: #"{"text":"Hi There","mode":"kebab"}"#)
        XCTAssertEqual(t, "hi-there")
        let b = await Base64Tool().invoke(arguments: #"{"text":"aGVsbG8=","mode":"decode"}"#)
        XCTAssertEqual(b, "hello")
        let w = await WordCountTool().invoke(arguments: #"{"text":"one two three"}"#)
        XCTAssertTrue(w.contains("3 words"))
        let j = await JSONFormatTool().invoke(arguments: #"{"json":"{\"b\":1,\"a\":2}","mode":"minify"}"#)
        XCTAssertEqual(j, #"{"a":2,"b":1}"#)
    }

    func testBundleNames() {
        XCTAssertEqual(Set(TextTools.all().map(\.name)),
                       ["text_transform", "base64", "word_count", "json_format"])
    }
}
