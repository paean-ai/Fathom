import XCTest
@testable import Fathom

final class InspectToolsTests: XCTestCase {

    // MARK: ColorConvert

    func testHexToRGBIncludingShorthand() {
        XCTAssertTrue(ColorConvert.hexToRGB("#FF5733")! == (255, 87, 51))
        XCTAssertTrue(ColorConvert.hexToRGB("FF5733")! == (255, 87, 51))
        XCTAssertTrue(ColorConvert.hexToRGB("#fff")! == (255, 255, 255))
        XCTAssertNil(ColorConvert.hexToRGB("#GG0000"))
        XCTAssertNil(ColorConvert.hexToRGB("#12345"))
    }

    func testRGBToHexAndDescribe() {
        XCTAssertEqual(ColorConvert.rgbToHex(255, 87, 51), "#FF5733")
        XCTAssertNil(ColorConvert.rgbToHex(256, 0, 0))
        XCTAssertNil(ColorConvert.rgbToHex(-1, 0, 0))
        XCTAssertEqual(ColorConvert.describe("#FF5733"), "#FF5733 = rgb(255, 87, 51)")
        XCTAssertEqual(ColorConvert.describe("255, 87, 51"), "rgb(255, 87, 51) = #FF5733")
        XCTAssertEqual(ColorConvert.describe("#fff"), "#FFFFFF = rgb(255, 255, 255)")
        XCTAssertNil(ColorConvert.describe("notacolor"))
        XCTAssertNil(ColorConvert.describe("999,0,0"))
    }

    // MARK: NatoPhonetic

    func testNato() {
        XCTAssertEqual(NatoPhonetic.spell("Cat"), "Charlie Alfa Tango")
        XCTAssertEqual(NatoPhonetic.spell("A1"), "Alfa One")
        XCTAssertEqual(NatoPhonetic.spell("A B"), "Alfa (space) Bravo")
        XCTAssertEqual(NatoPhonetic.spell("a-b"), "Alfa - Bravo")
        XCTAssertNil(NatoPhonetic.spell(""))
    }

    // MARK: CharFrequency

    func testCharFrequency() {
        let rows = CharFrequency.analyze("aAaB b!")
        XCTAssertEqual(rows.first?.letter, "a")
        XCTAssertEqual(rows.first?.count, 3)
        XCTAssertEqual(rows[1].letter, "b")
        XCTAssertEqual(rows[1].count, 2)

        let four = CharFrequency.analyze("abcd")
        XCTAssertEqual(four.reduce(0.0) { $0 + $1.percent }, 100.0, accuracy: 1e-9)
        XCTAssertEqual(four.count, 4)

        XCTAssertEqual(CharFrequency.analyze("zyx").map(\.letter), ["x", "y", "z"])
        XCTAssertTrue(CharFrequency.analyze("123 !!! ...").isEmpty)
        XCTAssertEqual(CharFrequency.table(CharFrequency.analyze("123")), "")
        XCTAssertEqual(CharFrequency.table(CharFrequency.analyze("aaab"), limit: 1), "A  3  (75.0%)")
    }

    // MARK: AsciiChart

    func testAsciiChart() {
        let a = AsciiChart.parse("Jan: 8, Feb: 5, Mar: 3")
        XCTAssertEqual(a.map(\.label), ["Jan", "Feb", "Mar"])
        XCTAssertEqual(a.map(\.value), [8, 5, 3])
        XCTAssertEqual(AsciiChart.parse("Q1: 1200\nQ2: 900").map(\.value), [1200, 900])

        let chart = AsciiChart.bars([("Jan", 8), ("Feb", 4)], width: 8)
        let lines = chart.components(separatedBy: "\n")
        XCTAssertEqual(lines[0].filter { $0 == "█" }.count, 8)
        XCTAssertEqual(lines[1].filter { $0 == "█" }.count, 4)
        XCTAssertTrue(lines[0].hasSuffix(" 8"), lines[0])

        XCTAssertNil(AsciiChart.render("no pairs here"))
        XCTAssertNil(AsciiChart.render(""))
        let r = AsciiChart.render("A: 2.5, B: 5", width: 10)
        XCTAssertNotNil(r)
        XCTAssertTrue(r!.contains(" 2.5"), r ?? "")
        XCTAssertTrue(r!.contains(" 5"), r ?? "")
        XCTAssertFalse(AsciiChart.bars([("X", 0), ("Y", 0)], width: 10).contains("█"))
    }

    // MARK: Tools

    func testToolsInvoke() async {
        let c = await ColorTool().invoke(arguments: ##"{"value":"#FF5733"}"##)
        XCTAssertEqual(c, "#FF5733 = rgb(255, 87, 51)")
        let n = await NatoTool().invoke(arguments: #"{"text":"Cat"}"#)
        XCTAssertEqual(n, "Charlie Alfa Tango")
        let f = await CharFrequencyTool().invoke(arguments: #"{"text":"aaab","top":"1"}"#)
        XCTAssertTrue(f.contains("A  3"))
        let b = await BarChartTool().invoke(arguments: #"{"data":"Jan: 8, Feb: 4"}"#)
        XCTAssertTrue(b.contains("█"))
    }

    func testBundleNames() {
        XCTAssertEqual(Set(InspectTools.all().map(\.name)), ["color", "nato", "char_frequency", "bar_chart"])
    }
}
