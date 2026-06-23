import XCTest
@testable import Fathom

final class TextUtilsTests: XCTestCase {

    func testPalindromeAndAnagram() {
        XCTAssertTrue(TextCheck.isPalindrome("A man, a plan, a canal: Panama"))
        XCTAssertFalse(TextCheck.isPalindrome("hello"))
        XCTAssertFalse(TextCheck.isPalindrome("!!!"))
        XCTAssertTrue(TextCheck.isAnagram("Listen", "Silent"))
        XCTAssertFalse(TextCheck.isAnagram("abc", "abcd"))
    }

    func testTruncate() {
        XCTAssertEqual(TextTruncate.toChars("Hello World", 5), "Hello…")
        XCTAssertEqual(TextTruncate.toChars("Hi", 5), "Hi")           // shorter than limit
        XCTAssertEqual(TextTruncate.toWords("one two three four", 2), "one two…")
    }

    func testHeadlineCase() {
        XCTAssertEqual(HeadlineCase.titleize("the lord of the rings"), "The Lord of the Rings")
        XCTAssertEqual(HeadlineCase.titleize("a tale of two cities"), "A Tale of Two Cities")
    }

    func testAcronym() {
        XCTAssertEqual(Acronym.make("Portable Document Format"), "PDF")
        XCTAssertEqual(Acronym.make("the United States of America", skipMinor: true), "USA")
    }

    func testToolsInvoke() async {
        let p = await PalindromeTool().invoke(arguments: #"{"text":"racecar"}"#)
        XCTAssertTrue(p.contains("is a palindrome"))
        let acr = await AcronymTool().invoke(arguments: #"{"phrase":"Portable Document Format"}"#)
        XCTAssertTrue(acr.contains("PDF"))
    }

    func testBundleNames() {
        XCTAssertEqual(Set(TextUtils.all().map(\.name)),
                       ["palindrome", "anagram", "truncate", "headline_case", "acronym"])
    }
}
