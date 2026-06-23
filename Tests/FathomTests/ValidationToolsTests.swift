import XCTest
@testable import Fathom

final class ValidationToolsTests: XCTestCase {

    func testLuhn() {
        XCTAssertTrue(Luhn.isValid("4539 1488 0343 6467"))   // valid Visa test number
        XCTAssertFalse(Luhn.isValid("1234 5678 9012 3456"))
        XCTAssertFalse(Luhn.isValid("7"))
    }

    func testEmail() {
        XCTAssertTrue(Email.isValid("user.name+tag@example.co.uk"))
        XCTAssertTrue(Email.isValid("  trimmed@x.io  "))
        XCTAssertFalse(Email.isValid("no-at-sign"))
        XCTAssertFalse(Email.isValid("spaces in@b.com"))
    }

    func testPasswordStrength() {
        XCTAssertEqual(PasswordStrength.evaluate("abc")?.label, "very weak")
        XCTAssertEqual(PasswordStrength.evaluate("Ab1!")?.poolSize, 26 + 26 + 10 + 32)
        XCTAssertEqual(PasswordStrength.evaluate("CorrectHorseBatteryStaple1!")?.label, "very strong")
        XCTAssertNil(PasswordStrength.evaluate(""))
    }

    func testToolsInvoke() async {
        let l = await LuhnTool().invoke(arguments: #"{"value":"4539148803436467"}"#)
        XCTAssertTrue(l.contains("is valid"))
        let e = await EmailValidatorTool().invoke(arguments: #"{"email":"a@b.com"}"#)
        XCTAssertTrue(e.contains("a valid"))
    }

    func testBundleNames() {
        XCTAssertEqual(Set(ValidationTools.all().map(\.name)), ["luhn", "validate_email", "password_strength"])
    }
}
