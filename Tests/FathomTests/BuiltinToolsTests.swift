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

    // MARK: CurrentDateTimeTool (injectable clock)

    func testCurrentDateTimeToolUsesInjectedClock() async {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14T22:13:20Z
        let tool = CurrentDateTimeTool(now: { fixed })
        let out = await tool.invoke(arguments: "{}")
        XCTAssertTrue(out.hasPrefix("2023-11-14") || out.hasPrefix("2023-11-15"),
                      "ISO-8601 from the injected clock (TZ-dependent day): \(out)")
        XCTAssertFalse(tool.isMutating, "reading the clock is not a mutation")
    }
}
