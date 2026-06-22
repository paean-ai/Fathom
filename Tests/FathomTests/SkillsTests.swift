import XCTest
@testable import Fathom

final class SkillsTests: XCTestCase {

    func testParseSkillMarkdown() {
        let md = """
        ---
        name: pdf-summarizer
        description: Extract and summarize PDF documents
        allowed-tools: read_file, summarize
        ---
        First extract the text, then produce a 3-bullet summary.
        """
        let skill = Skill.parse(markdown: md)
        XCTAssertEqual(skill?.name, "pdf-summarizer")
        XCTAssertEqual(skill?.description, "Extract and summarize PDF documents")
        XCTAssertEqual(skill?.allowedTools, ["read_file", "summarize"])
        XCTAssertEqual(skill?.instructions, "First extract the text, then produce a 3-bullet summary.")
    }

    func testParseRequiresName() {
        XCTAssertNil(Skill.parse(markdown: "---\ndescription: no name here\n---\nbody"))
        XCTAssertNil(Skill.parse(markdown: "just prose, no frontmatter"))
    }

    func testSystemAddendumIncludesInstructionsAndTools() {
        let skill = Skill(name: "git", description: "Git ops", instructions: "Stage, then commit.",
                          allowedTools: ["run_command"])
        let s = skill.systemAddendum
        XCTAssertTrue(s.contains("## Skill: git"))
        XCTAssertTrue(s.contains("Stage, then commit."))
        XCTAssertTrue(s.contains("run_command"))
    }

    func testRegistryMatchesByKeywordAndName() {
        var reg = SkillRegistry()
        reg.register(Skill(name: "pdf", description: "summarize pdf documents", instructions: "..."))
        reg.register(Skill(name: "git", description: "version control commits", instructions: "..."))

        let m = reg.match("please summarize this pdf for me")
        XCTAssertEqual(m.first?.name, "pdf")
        XCTAssertTrue(reg.match("make a git commit").contains { $0.name == "git" })
        XCTAssertTrue(reg.match("what's the weather").isEmpty)   // no overlap
    }

    func testRegisterReplacesByName() {
        var reg = SkillRegistry()
        reg.register(Skill(name: "x", description: "v1", instructions: "one"))
        reg.register(Skill(name: "x", description: "v2", instructions: "two"))
        XCTAssertEqual(reg.skills.count, 1)
        XCTAssertEqual(reg.skills.first?.instructions, "two")
    }

    func testSystemAddendumForQueryCombinesTopSkills() {
        var reg = SkillRegistry()
        reg.register(Skill(name: "pdf", description: "summarize pdf documents", instructions: "Do PDF things."))
        let addendum = reg.systemAddendum(for: "summarize a pdf")
        XCTAssertTrue(addendum.contains("Do PDF things."))
        XCTAssertTrue(reg.systemAddendum(for: "totally unrelated").isEmpty)
    }
}
