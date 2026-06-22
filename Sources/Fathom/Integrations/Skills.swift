import Foundation

/// Skills — reusable, named playbooks that teach an agent how to handle a class of task (like
/// Claude Code's SKILL.md files). A skill bundles a description (so the agent knows WHEN to use
/// it), instructions (injected into the system prompt when the skill is active), and optionally a
/// whitelist of tools it may use. `SkillRegistry` picks the relevant skill(s) for a query. Pure +
/// deterministic → unit-testable. Skills compose with `OrchestratorTool`s — the skill steers,
/// the tools act.
public struct Skill: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let description: String
    public let instructions: String
    /// When non-empty, only these tool names should be offered while the skill is active.
    public let allowedTools: [String]

    public init(name: String, description: String, instructions: String, allowedTools: [String] = []) {
        self.name = name; self.description = description
        self.instructions = instructions; self.allowedTools = allowedTools
    }

    /// The block injected into the system prompt when this skill is active.
    public var systemAddendum: String {
        var s = "## Skill: \(name)\n\(instructions.trimmingCharacters(in: .whitespacesAndNewlines))"
        if !allowedTools.isEmpty {
            s += "\nUse only these tools for this skill: \(allowedTools.joined(separator: ", "))."
        }
        return s
    }

    /// Keywords used to decide relevance — name + description words, lowercased, length > 2.
    var keywords: Set<String> {
        let raw = (name + " " + description).lowercased().split { !$0.isLetter && !$0.isNumber }
        return Set(raw.map(String.init).filter { $0.count > 2 })
    }

    /// Parse a Claude-Code-style SKILL.md: `---` YAML-ish frontmatter (name, description,
    /// allowed-tools) followed by the instruction body. nil if there's no `name`.
    public static func parse(markdown: String) -> Skill? {
        var name = "", description = "", allowed: [String] = []
        var body = markdown

        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("---") {
            let afterOpen = trimmed.dropFirst(3)
            if let closeRange = afterOpen.range(of: "\n---") {
                let front = afterOpen[..<closeRange.lowerBound]
                body = String(afterOpen[closeRange.upperBound...])
                for line in front.split(separator: "\n") {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    switch key {
                    case "name": name = value
                    case "description": description = value
                    case "allowed-tools", "allowedtools", "tools":
                        allowed = value.split { $0 == "," }.map { $0.trimmingCharacters(in: .whitespaces) }
                                       .filter { !$0.isEmpty }
                    default: break
                    }
                }
            }
        }
        let instructions = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return Skill(name: name, description: description, instructions: instructions, allowedTools: allowed)
    }
}

/// Holds available skills and selects the relevant one(s) for a query by keyword overlap. Pure +
/// deterministic.
public struct SkillRegistry: Sendable {
    public private(set) var skills: [Skill]
    public init(_ skills: [Skill] = []) { self.skills = skills }

    public mutating func register(_ skill: Skill) {
        skills.removeAll { $0.name == skill.name }   // replace by name
        skills.append(skill)
    }

    /// Skills relevant to `query`, most-relevant first. A skill matches when its name appears in
    /// the query or it shares ≥1 keyword; ties broken by name for determinism.
    public func match(_ query: String) -> [Skill] {
        let q = query.lowercased()
        let qWords = Set(q.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        var scored: [(skill: Skill, score: Int)] = []
        for skill in skills {
            let overlap = skill.keywords.intersection(qWords).count
            let nameHit = q.contains(skill.name.lowercased()) ? 5 : 0
            let score = overlap + nameHit
            if score > 0 { scored.append((skill, score)) }
        }
        scored.sort { a, b in a.score != b.score ? a.score > b.score : a.skill.name < b.skill.name }
        return scored.map(\.skill)
    }

    /// Combined system-prompt addendum for the top `limit` skills matching the query (empty if
    /// none match) — paste after the base system prompt.
    public func systemAddendum(for query: String, limit: Int = 2) -> String {
        match(query).prefix(limit).map(\.systemAddendum).joined(separator: "\n\n")
    }
}
