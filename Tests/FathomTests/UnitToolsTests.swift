import XCTest
@testable import Fathom

final class UnitToolsTests: XCTestCase {

    func testTemperature() {
        XCTAssertEqual(Temperature.convert(100, from: "C", to: "F")!, 212, accuracy: 1e-9)
        XCTAssertEqual(Temperature.convert(32, from: "F", to: "C")!, 0, accuracy: 1e-9)
        XCTAssertEqual(Temperature.convert(0, from: "C", to: "K")!, 273.15, accuracy: 1e-9)
        XCTAssertNil(Temperature.convert(1, from: "X", to: "C"))
    }

    func testByteSize() {
        XCTAssertEqual(ByteSize.humanize(1_500_000), "1.5 MB")
        XCTAssertEqual(ByteSize.humanize(0), "0 bytes")
        XCTAssertEqual(ByteSize.parse("1.5 MB"), 1_500_000)
        XCTAssertEqual(ByteSize.parse("2GB"), 2_000_000_000)
    }

    func testDuration() {
        XCTAssertEqual(HumanDuration.humanize(3661), "1h 1m 1s")
        XCTAssertEqual(HumanDuration.humanize(0), "0s")
        XCTAssertEqual(HumanDuration.parse("1h 30m"), 5400)
        XCTAssertEqual(HumanDuration.parse("1:30:00"), 5400)
        XCTAssertEqual(HumanDuration.parse("90"), 90)
    }

    func testToolsInvoke() async {
        let t = await TemperatureTool().invoke(arguments: #"{"value":"100","from":"C","to":"F"}"#)
        XCTAssertTrue(t.contains("212"))
        let f = await FileSizeTool().invoke(arguments: #"{"value":"1500000"}"#)
        XCTAssertTrue(f.contains("1.5 MB"))
    }

    func testBundleNames() {
        XCTAssertEqual(Set(UnitTools.all().map(\.name)), ["temperature", "file_size", "duration"])
    }
}
