import XCTest
@testable import Fathom

final class CipherToolsTests: XCTestCase {

    func testCaesar() {
        XCTAssertEqual(Caesar.shift("Hello, World!", by: 13), "Uryyb, Jbeyq!")
        XCTAssertEqual(Caesar.shift(Caesar.shift("abc", by: 13), by: 13), "abc")   // ROT13 self-inverse
        XCTAssertEqual(Caesar.shift("abc", by: 1), "bcd")
    }

    func testVigenere() {
        XCTAssertEqual(Vigenere.transform("ATTACKATDAWN", key: "LEMON", decode: false), "LXFOPVEFRNHR")
        let enc = Vigenere.transform("Hello there!", key: "key", decode: false)!
        XCTAssertEqual(Vigenere.transform(enc, key: "key", decode: true), "Hello there!")
        XCTAssertNil(Vigenere.transform("hi", key: "123", decode: false))
    }

    func testMorse() {
        XCTAssertEqual(Morse.encode("SOS"), "... --- ...")
        XCTAssertEqual(Morse.encode("HI ME"), ".... .. / -- .")
        XCTAssertEqual(Morse.decode(Morse.encode("HELLO WORLD")!), "HELLO WORLD")
        XCTAssertNil(Morse.encode(""))
    }

    func testToolsInvoke() async {
        let caesar = await CaesarTool().invoke(arguments: #"{"text":"abc"}"#)
        XCTAssertEqual(caesar, "nop")  // ROT13 default
        let morse = await MorseTool().invoke(arguments: #"{"text":"SOS"}"#)
        XCTAssertEqual(morse, "... --- ...")
        let url = await URLEncodeTool().invoke(arguments: #"{"text":"a b&c"}"#)
        XCTAssertEqual(url, "a%20b%26c")
        let dec = await URLEncodeTool().invoke(arguments: #"{"text":"a%20b","mode":"decode"}"#)
        XCTAssertEqual(dec, "a b")
    }

    func testBundleNames() {
        XCTAssertEqual(Set(CipherTools.all().map(\.name)), ["caesar", "vigenere", "morse", "url_encode"])
    }
}
