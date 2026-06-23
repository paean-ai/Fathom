import XCTest
@testable import Fathom

final class StatsToolsTests: XCTestCase {

    func testParseAndBasics() {
        let xs = Numbers.parse("1, 2 3\n4;5")
        XCTAssertEqual(xs, [1, 2, 3, 4, 5])
        XCTAssertEqual(Numbers.mean(xs), 3)
        XCTAssertEqual(Numbers.median(xs), 3)
        XCTAssertEqual(Numbers.median([1, 2, 3, 4]), 2.5)
        XCTAssertEqual(Numbers.stdev([1, 2, 3, 4, 5]), 2.0.squareRoot(), accuracy: 1e-9)
    }

    func testQuartiles() {
        let q = Numbers.quartiles([1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(q?.q1, 2.5)
        XCTAssertEqual(q?.q2, 4.5)
        XCTAssertEqual(q?.q3, 6.5)
        XCTAssertEqual(q?.iqr, 4)
        XCTAssertNil(Numbers.quartiles([]))
    }

    func testPercentile() {
        XCTAssertEqual(Numbers.percentile([1, 2, 3, 4], 30)!, 1.9, accuracy: 1e-9)
        XCTAssertEqual(Numbers.percentile(Array(1...10).map(Double.init), 90)!, 9.1, accuracy: 1e-9)
        XCTAssertEqual(Numbers.percentile([7], 42)!, 7)
        XCTAssertNil(Numbers.percentile([], 50))
    }

    func testToolsInvoke() async {
        let s = await NumberStatsTool().invoke(arguments: #"{"data":"1,2,3,4,5"}"#)
        XCTAssertTrue(s.contains("mean 3"))
        XCTAssertTrue(s.contains("n=5"))
        let q = await QuartilesTool().invoke(arguments: #"{"data":"1 2 3 4 5 6 7 8"}"#)
        XCTAssertTrue(q.contains("Q1 2.5"))
        let p = await PercentileTool().invoke(arguments: #"{"data":"1,2,3,4,5,6,7,8,9,10","p":"90"}"#)
        XCTAssertTrue(p.contains("9.1"))
        let empty = await NumberStatsTool().invoke(arguments: #"{"data":"nope"}"#)
        XCTAssertTrue(empty.contains("No numbers"))
    }

    func testBundleNames() {
        XCTAssertEqual(Set(StatsTools.all().map(\.name)), ["number_stats", "quartiles", "percentile"])
    }
}
