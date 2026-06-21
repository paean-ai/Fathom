import XCTest
@testable import Fathom

final class BuiltinToolsTests: XCTestCase {

    // MARK: Calculator (pure)

    func testArithmeticPrecedenceAndAssociativity() {
        XCTAssertEqual(Calculator.eval("(3 + 4) * 2 ^ 3"), 56)   // (7) * 8
        XCTAssertEqual(Calculator.eval("2 ^ 3 ^ 2"), 512)        // right-assoc: 2^(3^2) = 2^9
        XCTAssertEqual(Calculator.eval("10 % 3"), 1)
        XCTAssertEqual(Calculator.eval("-5 + 2"), -3)
        XCTAssertEqual(Calculator.eval("1 + 2 * 3 - 4 / 2"), 5)
    }

    func testCalculatorRejectsBadInput() {
        XCTAssertNil(Calculator.eval("5 / 0"), "no divide by zero")
        XCTAssertNil(Calculator.eval("2 +"), "incomplete expression")
        XCTAssertNil(Calculator.eval("hello"), "non-arithmetic")
        XCTAssertNil(Calculator.eval(""), "empty")
    }

    func testFormatPrefersIntegers() {
        XCTAssertEqual(Calculator.format(56), "56")
        XCTAssertEqual(Calculator.format(2.5), "2.5")
    }

    // MARK: CalculatorTool

    func testCalculatorToolInvoke() async {
        let tool = CalculatorTool()
        XCTAssertEqual(tool.name, "calculate")
        let ok = await tool.invoke(arguments: #"{"expression":"(3+4)*2^3"}"#)
        XCTAssertEqual(ok, "(3+4)*2^3 = 56")
        let bad = await tool.invoke(arguments: #"{"expression":"oops"}"#)
        XCTAssertTrue(bad.contains("Couldn't evaluate"))
        let missing = await tool.invoke(arguments: "{}")
        XCTAssertTrue(missing.contains("Missing"))
        // It advertises a valid OpenAI-style schema.
        let fn = tool.schema["function"] as? [String: Any]
        XCTAssertEqual(fn?["name"] as? String, "calculate")
    }

    // MARK: UnitConvert (pure)

    func testUnitConversions() {
        XCTAssertEqual(UnitConvert.convert(1, from: "km", to: "m"), 1000)
        XCTAssertEqual(UnitConvert.convert(1, from: "kg", to: "g"), 1000)
        XCTAssertEqual(UnitConvert.convert(100, from: "celsius", to: "fahrenheit"), 212)
        XCTAssertEqual(UnitConvert.convert(0, from: "c", to: "k"), 273.15)
        // Aliases/plurals canonicalize.
        XCTAssertEqual(UnitConvert.canonical("miles"), "mi")
        XCTAssertEqual(UnitConvert.canonical("Kilograms"), "kg")
    }

    func testUnitConvertRejectsCrossDimensionAndUnknown() {
        XCTAssertNil(UnitConvert.convert(1, from: "m", to: "kg"), "length → mass is invalid")
        XCTAssertNil(UnitConvert.convert(1, from: "banana", to: "m"), "unknown unit")
    }

    func testUnitConvertToolInvoke() async {
        let tool = UnitConvertTool()
        let out = await tool.invoke(arguments: #"{"value":10,"from":"km","to":"m"}"#)
        XCTAssertEqual(out, "10 km = 10000 m")
        let bad = await tool.invoke(arguments: #"{"value":1,"from":"m","to":"kg"}"#)
        XCTAssertTrue(bad.contains("Can't convert"))
    }

    // MARK: CurrentDateTimeTool (injectable clock)

    func testCurrentDateTimeToolUsesInjectedClock() async {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14T22:13:20Z
        let tool = CurrentDateTimeTool(now: { fixed })
        let out = await tool.invoke(arguments: "{}")
        XCTAssertTrue(out.hasPrefix("2023-11-14") || out.hasPrefix("2023-11-15"),
                      "ISO-8601 from the injected clock (TZ-dependent day): \(out)")
        XCTAssertFalse(tool.isMutating, "reading the clock is not a mutation")
    }

    func testCurrentDateTimeHumanStyle() async {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        // The human render is a friendly sentence with weekday + month name.
        let human = CurrentDateTimeTool.render(fixed, style: .human)
        XCTAssertTrue(human.contains("November"), "human style spells the month: \(human)")
        XCTAssertTrue(human.contains("2023"))
        // The tool honors the configured style.
        let tool = CurrentDateTimeTool(now: { fixed }, style: .human)
        let out = await tool.invoke(arguments: "{}")
        XCTAssertEqual(out, human)
    }
}
