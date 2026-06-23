import XCTest
@testable import Fathom

final class NumberFormatToolsTests: XCTestCase {

    // MARK: NumberWords

    func testSpellSmallNumbers() {
        XCTAssertEqual(NumberWords.spell(0), "zero")
        XCTAssertEqual(NumberWords.spell(7), "seven")
        XCTAssertEqual(NumberWords.spell(19), "nineteen")
        XCTAssertEqual(NumberWords.spell(23), "twenty-three")
        XCTAssertEqual(NumberWords.spell(40), "forty")
    }

    func testSpellHundredsAndThousands() {
        XCTAssertEqual(NumberWords.spell(100), "one hundred")
        XCTAssertEqual(NumberWords.spell(305), "three hundred five")
        XCTAssertEqual(NumberWords.spell(1234), "one thousand two hundred thirty-four")
        XCTAssertEqual(NumberWords.spell(1000000), "one million")
    }

    func testSpellNegativeAndSkippedGroups() {
        XCTAssertEqual(NumberWords.spell(-5), "negative five")
        XCTAssertEqual(NumberWords.spell(-21), "negative twenty-one")
        XCTAssertEqual(NumberWords.spell(1000005), "one million five")   // no "zero thousand"
    }

    // MARK: NumberFormat

    func testGroupsThousands() {
        XCTAssertEqual(NumberFormat.grouped("1234567"), "1,234,567")
        XCTAssertEqual(NumberFormat.grouped("1000"), "1,000")
        XCTAssertEqual(NumberFormat.grouped("999"), "999")
    }

    func testPreservesSignAndDecimalsAndRegroups() {
        XCTAssertEqual(NumberFormat.grouped("-1234567.89"), "-1,234,567.89")
        XCTAssertEqual(NumberFormat.grouped("1234.5"), "1,234.5")
        XCTAssertEqual(NumberFormat.grouped("1,2,3,4"), "1,234")
        XCTAssertNil(NumberFormat.grouped("abc"))
        XCTAssertNil(NumberFormat.grouped("12.3.4"))
    }

    // MARK: NumberBases

    func testParsesEachInputBase() {
        XCTAssertEqual(NumberBases.parse("255"), 255)
        XCTAssertEqual(NumberBases.parse("0xff"), 255)
        XCTAssertEqual(NumberBases.parse("0b1010"), 10)
        XCTAssertEqual(NumberBases.parse("0o17"), 15)
        XCTAssertEqual(NumberBases.parse("-10"), -10)
        XCTAssertNil(NumberBases.parse("zzz"))
        XCTAssertNil(NumberBases.parse("0xzz"))
    }

    func testDescribesAllBases() {
        let d = NumberBases.describe("255")
        XCTAssertNotNil(d)
        XCTAssertTrue(d!.contains("decimal 255"), d ?? "")
        XCTAssertTrue(d!.contains("hex 0xff"), d ?? "")
        XCTAssertTrue(d!.contains("binary 0b11111111"), d ?? "")
        XCTAssertTrue(d!.contains("octal 0o377"), d ?? "")
        XCTAssertTrue(NumberBases.describe("0xff")!.contains("decimal 255"))
        XCTAssertTrue(NumberBases.describe("-10")!.contains("hex -0xa"))
    }

    // MARK: Tools

    func testToolsInvoke() async {
        let w = await NumberToWordsTool().invoke(arguments: #"{"value":"1234"}"#)
        XCTAssertTrue(w.contains("one thousand two hundred thirty-four"))
        let f = await NumberFormatTool().invoke(arguments: #"{"value":"1234567"}"#)
        XCTAssertEqual(f, "1,234,567")
        let b = await NumberBasesTool().invoke(arguments: #"{"value":"255"}"#)
        XCTAssertTrue(b.contains("hex 0xff"))
    }

    func testBundleNames() {
        XCTAssertEqual(Set(NumberFormatTools.all().map(\.name)), ["number_to_words", "number_format", "number_bases"])
    }
}
