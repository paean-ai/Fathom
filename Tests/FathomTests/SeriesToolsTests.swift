import XCTest
@testable import Fathom

final class SeriesToolsTests: XCTestCase {

    func testOutliers() {
        let r = Series.outliers([10, 11, 12, 13, 14, 100])
        XCTAssertEqual(r?.high, [100])
        XCTAssertEqual(r?.low, [])
        XCTAssertNil(Series.outliers([1, 2, 3]))   // <4
    }

    func testZScore() {
        XCTAssertEqual(Series.zScore(of: 5, in: [1, 2, 3, 4, 5])!, 2.0.squareRoot(), accuracy: 1e-9)
        XCTAssertNil(Series.zScore(of: 5, in: [5, 5, 5]))   // zero spread
    }

    func testMovingAverageAndRunningTotal() {
        XCTAssertEqual(Series.movingAverage([1, 2, 3, 4, 5], window: 3), [2, 3, 4])
        XCTAssertNil(Series.movingAverage([1], window: 2))
        XCTAssertEqual(Series.runningTotal([1, 2, 3, 4]), [1, 3, 6, 10])
    }

    func testPctChangeAndCorrelation() {
        let c = Series.pctChange([100, 110, 99])!
        XCTAssertEqual(c[0]!, 10, accuracy: 1e-9)
        XCTAssertEqual(c[1]!, -10, accuracy: 1e-9)
        XCTAssertNil(Series.pctChange([10, 0, 5])![1])   // base 0 → nil
        XCTAssertEqual(Series.correlation([1, 2, 3, 4], [2, 4, 6, 8])!, 1.0, accuracy: 1e-9)
        XCTAssertNil(Series.correlation([1, 2, 3], [1, 2]))   // length mismatch
    }

    func testToolsInvoke() async {
        let o = await OutliersTool().invoke(arguments: #"{"data":"10,11,12,13,14,100"}"#)
        XCTAssertTrue(o.contains("100"))
        let ma = await MovingAverageTool().invoke(arguments: #"{"data":"1,2,3,4,5","window":"3"}"#)
        XCTAssertTrue(ma.contains("2, 3, 4"))
        let corr = await CorrelationTool().invoke(arguments: #"{"x":"1,2,3,4","y":"2,4,6,8"}"#)
        XCTAssertTrue(corr.contains("r = 1"))
    }

    func testStandardizeAndDescribe() {
        let zs = Series.standardize([10, 20, 30, 40])!
        XCTAssertEqual(zs.reduce(0, +), 0, accuracy: 1e-9)   // zero-mean
        XCTAssertNil(Series.standardize([5, 5, 5]))          // zero spread
        XCTAssertTrue(Series.describe(0.95).contains("very strong"))
        XCTAssertTrue(Series.describe(-0.8).contains("negative"))
        XCTAssertEqual(Series.describe(0.0), "no linear relationship")
    }

    func testBundleNames() {
        XCTAssertEqual(Set(SeriesTools.all().map(\.name)),
                       ["outliers", "z_score", "correlation", "moving_average", "running_total", "pct_change"])
    }
}
