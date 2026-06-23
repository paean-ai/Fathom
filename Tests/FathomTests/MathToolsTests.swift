import XCTest
@testable import Fathom

final class MathToolsTests: XCTestCase {

    func testRoman() {
        XCTAssertEqual(RomanNumeral.toRoman(1994), "MCMXCIV")
        XCTAssertEqual(RomanNumeral.fromRoman("MCMXCIV"), 1994)
        XCTAssertNil(RomanNumeral.toRoman(4000))
        XCTAssertNil(RomanNumeral.fromRoman("IIII"))   // malformed
        XCTAssertEqual(RomanNumeral.convert("49"), "XLIX")
        XCTAssertEqual(RomanNumeral.convert("IV"), "4")
    }

    func testOrdinal() {
        XCTAssertEqual(Ordinal.format(1), "1st")
        XCTAssertEqual(Ordinal.format(22), "22nd")
        XCTAssertEqual(Ordinal.format(13), "13th")
        XCTAssertEqual(Ordinal.format(103), "103rd")
    }

    func testBaseConvert() {
        XCTAssertEqual(BaseConvert.convert("255", from: 10, to: 16), "FF")
        XCTAssertEqual(BaseConvert.convert("FF", from: 16, to: 2), "11111111")
        XCTAssertNil(BaseConvert.convert("2", from: 2, to: 10))   // '2' invalid in base 2
        XCTAssertEqual(BaseConvert.convert("-10", from: 10, to: 2), "-1010")
    }

    func testIntMath() {
        XCTAssertEqual(IntMath.gcd(12, 18), 6)
        XCTAssertEqual(IntMath.lcm(4, 6), 12)
        XCTAssertTrue(IntMath.isPrime(97))
        XCTAssertFalse(IntMath.isPrime(91))   // 7×13
        XCTAssertEqual(IntMath.factorize(60), [2, 2, 3, 5])
        XCTAssertEqual(IntMath.grouped(1234567), "1,234,567")
    }

    func testToolsInvoke() async {
        let r = await RomanTool().invoke(arguments: #"{"value":"1994"}"#)
        XCTAssertTrue(r.contains("MCMXCIV"))
        let f = await FactorizeTool().invoke(arguments: #"{"value":"60"}"#)
        XCTAssertTrue(f.contains("2 × 2 × 3 × 5"))
        let b = await BaseConvertTool().invoke(arguments: #"{"value":"255","from":"10","to":"16"}"#)
        XCTAssertTrue(b.contains("FF"))
    }

    func testBundleNames() {
        XCTAssertEqual(Set(MathTools.all().map(\.name)),
                       ["roman_numeral", "ordinal", "convert_base", "gcd_lcm", "factorize"])
    }
}
