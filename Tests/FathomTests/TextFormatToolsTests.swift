import XCTest
@testable import Fathom

final class TextFormatToolsTests: XCTestCase {

    // MARK: Slugifier

    func testSlugify() {
        XCTAssertEqual(Slugifier.slugify("My Great Note!"), "my-great-note")
        XCTAssertEqual(Slugifier.slugify("Café résumé"), "cafe-resume")
        XCTAssertEqual(Slugifier.slugify("  multiple   spaces--and__symbols!! "), "multiple-spaces-and-symbols")
        XCTAssertEqual(Slugifier.slugify("hello world foo", maxLength: 11), "hello-world")
        XCTAssertEqual(Slugifier.slugify("！？。"), "")
        XCTAssertEqual(Slugifier.slugify(""), "")
    }

    // MARK: ListFormatter

    func testListNumberedAndBullet() {
        XCTAssertEqual(ListFormatter.format("a\nb\nc", style: "numbered"), "1. a\n2. b\n3. c")
        XCTAssertEqual(ListFormatter.format("a\nb", style: "bullet"), "- a\n- b")
    }

    func testListCommaAndOxford() {
        XCTAssertEqual(ListFormatter.format("a\nb\nc", style: "comma"), "a, b, c")
        XCTAssertEqual(ListFormatter.format("a\nb\nc", style: "and"), "a, b, and c")
        XCTAssertEqual(ListFormatter.format("x\ny", style: "and"), "x and y")
        XCTAssertEqual(ListFormatter.format("solo", style: "and"), "solo")
    }

    func testListStripsMarkersAndNilCases() {
        XCTAssertEqual(ListFormatter.format("1. a\n2. b", style: "bullet"), "- a\n- b")
        XCTAssertEqual(ListFormatter.format("- a\n* b", style: "numbered"), "1. a\n2. b")
        XCTAssertNil(ListFormatter.format("a\nb", style: "table"))
        XCTAssertNil(ListFormatter.format("   \n  ", style: "bullet"))
    }

    // MARK: ChecklistBuilder

    func testChecklist() {
        XCTAssertEqual(ChecklistBuilder.build("buy milk\ncall Sam"), "- [ ] buy milk\n- [ ] call Sam")
        XCTAssertEqual(ChecklistBuilder.build("- already\n* star\n1. numbered\n2) paren"),
                       "- [ ] already\n- [ ] star\n- [ ] numbered\n- [ ] paren")
        XCTAssertEqual(ChecklistBuilder.build("- [x] done thing\n- [ ] open thing\nplain"),
                       "- [x] done thing\n- [ ] open thing\n- [ ] plain")
        XCTAssertEqual(ChecklistBuilder.build("a\n\n   \nb"), "- [ ] a\n- [ ] b")
        XCTAssertNil(ChecklistBuilder.build("   \n  "))
        XCTAssertNil(ChecklistBuilder.build(""))
    }

    // MARK: MarkdownStripper

    func testStripMarkdown() {
        XCTAssertEqual(MarkdownStripper.strip("Some **bold** and *italic* and `code` here."),
                       "Some bold and italic and code here.")
        XCTAssertEqual(MarkdownStripper.strip("# Title\n- item one\n> a quote\n1. first"),
                       "Title\nitem one\na quote\nfirst")
        XCTAssertEqual(MarkdownStripper.strip("A [link](http://x.com) here."), "A link here.")
        XCTAssertEqual(MarkdownStripper.strip("![alt text](http://x.com/i.png)"), "alt text")
        XCTAssertEqual(MarkdownStripper.strip("the snake_case_var stays intact"), "the snake_case_var stays intact")
    }

    // MARK: Tools

    func testToolsInvoke() async {
        let s = await SlugifyTool().invoke(arguments: #"{"text":"My Great Note!"}"#)
        XCTAssertEqual(s, "my-great-note")
        let l = await FormatListTool().invoke(arguments: #"{"text":"a\nb\nc","style":"numbered"}"#)
        XCTAssertEqual(l, "1. a\n2. b\n3. c")
        let c = await MakeChecklistTool().invoke(arguments: #"{"data":"buy milk\ncall Sam"}"#)
        XCTAssertEqual(c, "- [ ] buy milk\n- [ ] call Sam")
        let m = await StripMarkdownTool().invoke(arguments: #"{"text":"Some **bold** here."}"#)
        XCTAssertEqual(m, "Some bold here.")
    }

    func testBundleNames() {
        XCTAssertEqual(Set(TextFormatTools.all().map(\.name)),
                       ["slugify", "format_list", "make_checklist", "strip_markdown"])
    }
}
