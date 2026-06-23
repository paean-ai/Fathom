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

    // MARK: load-from-directory

    func testLoadFromDirectoryReadsSkillFolders() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("fathom-skills-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }

        // skills/git/SKILL.md and skills/pdf/SKILL.md, plus a noise folder without a SKILL.md.
        func writeSkill(_ folder: String, _ contents: String) throws {
            let dir = root.appendingPathComponent(folder)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try contents.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        try writeSkill("git", "---\nname: git\ndescription: version control commits\n---\nStage then commit.")
        try writeSkill("pdf", "---\nname: pdf\ndescription: summarize pdf documents\n---\nExtract then summarize.")
        // A folder with no SKILL.md is ignored.
        try fm.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)

        let reg = SkillRegistry.load(fromDirectory: root.path)
        XCTAssertEqual(Set(reg.skills.map(\.name)), ["git", "pdf"])
        XCTAssertEqual(reg.match("make a git commit").first?.name, "git")
        XCTAssertTrue(reg.systemAddendum(for: "summarize a pdf").contains("Extract then summarize."))
    }

    func testLoadSkipsMalformedAndMissingDirectory() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("fathom-skills-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // A top-level .md without a name is skipped; a valid one loads.
        try "no frontmatter, no name".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "---\nname: solo\ndescription: a lone skill\n---\nDo the thing."
            .write(to: root.appendingPathComponent("solo.md"), atomically: true, encoding: .utf8)

        let reg = SkillRegistry.load(fromDirectory: root.path)
        XCTAssertEqual(reg.skills.map(\.name), ["solo"])
        // A directory that doesn't exist yields an empty registry, not a crash.
        XCTAssertTrue(SkillRegistry.load(fromDirectory: root.path + "/does-not-exist").skills.isEmpty)
    }
}
