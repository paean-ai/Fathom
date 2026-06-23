import Foundation

/// Generic text-presentation tools for the SDK — URL/filename slugs, list reformatting, markdown
/// checklist building, and markdown-to-plaintext stripping. Self-contained pure helpers + thin
/// `OrchestratorTool` wrappers. Pure → unit-testable.

/// Turns a string into a URL/filename-safe slug ("My Great Note!" → "my-great-note"). Folds
/// accents to ASCII, lowercases, and collapses any run of non-alphanumerics into a single hyphen.
public enum Slugifier {
    public static func slugify(_ s: String, maxLength: Int = 80) -> String {
        let folded = s.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US")).lowercased()
        var slug = folded.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        slug = trimHyphens(slug)
        if slug.count > maxLength {
            slug = trimHyphens(String(slug.prefix(maxLength)))
        }
        return slug
    }

    private static func trimHyphens(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

/// Reformats a newline-separated list — numbered, bulleted, comma-joined, or an Oxford-comma
/// sentence. Strips any existing bullet/number/checkbox first. nil on empty input or unknown style.
public enum ListFormatter {
    public static func format(_ text: String, style: String) -> String? {
        let items = text.components(separatedBy: "\n")
            .map { stripMarker($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
        guard !items.isEmpty else { return nil }

        switch style.lowercased() {
        case "numbered":
            return items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        case "bullet", "bulleted":
            return items.map { "- \($0)" }.joined(separator: "\n")
        case "comma":
            return items.joined(separator: ", ")
        case "and", "sentence":
            return oxford(items)
        default:
            return nil
        }
    }

    /// "a", "a and b", or "a, b, and c".
    private static func oxford(_ items: [String]) -> String {
        switch items.count {
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items.last!
        }
    }

    private static func stripMarker(_ s: String) -> String {
        var t = s
        for p in [#"^[-*+]\s+"#, #"^\d+[.)]\s+"#, #"^\[.\]\s*"#] {
            t = t.replacingOccurrences(of: p, with: "", options: .regularExpression)
        }
        return t.trimmingCharacters(in: .whitespaces)
    }
}

/// Turns a list of lines into a markdown checklist — convert notes or action items into `- [ ]`
/// tasks. Strips an existing list bullet/number and preserves a `[x]` done-state. nil if empty.
public enum ChecklistBuilder {
    public static func build(_ data: String) -> String? {
        var out: [String] = []
        for raw in data.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // Strip a leading list bullet ("- ", "* ", "+ ") or a number ("1. ", "2) ").
            if let m = line.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
                line.removeSubrange(m)
            } else if let m = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                line.removeSubrange(m)
            }

            // Detect + strip an existing checkbox, preserving done-state.
            var done = false
            if let m = line.range(of: #"^\[([ xX])\]\s*"#, options: .regularExpression) {
                done = line[m].contains("x") || line[m].contains("X")
                line.removeSubrange(m)
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { out.append("- [\(done ? "x" : " ")] \(trimmed)") }
        }
        return out.isEmpty ? nil : out.joined(separator: "\n")
    }
}

/// Strips markdown formatting to plain text — headings, bold/italic, links, images, inline code,
/// list bullets, blockquotes, and horizontal rules. Underscore-italic uses word boundaries so
/// `snake_case` words survive.
public enum MarkdownStripper {
    public static func strip(_ md: String) -> String {
        // Pass 1: line-level markers (headings, bullets, quotes); skip fenced code fences.
        var lines: [String] = []
        var inFence = false
        for var line in md.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); continue }
            if inFence { lines.append(line); continue }
            line = sub(line, #"^\s{0,3}#{1,6}\s+"#, "")        // heading
            line = sub(line, #"^\s*>\s?"#, "")                  // blockquote
            line = sub(line, #"^\s*[-*+]\s+"#, "")              // bullet
            line = sub(line, #"^\s*\d+[.)]\s+"#, "")            // numbered
            lines.append(line)
        }
        var text = lines.joined(separator: "\n")

        // Pass 2: inline markers (order matters).
        text = sub(text, #"!\[([^\]]*)\]\([^)]*\)"#, "$1")      // image → alt (before link)
        text = sub(text, #"\[([^\]]*)\]\([^)]*\)"#, "$1")       // link → text
        text = sub(text, #"\*\*(.+?)\*\*"#, "$1")               // bold *
        text = sub(text, #"__(.+?)__"#, "$1")                   // bold _
        text = sub(text, #"\*(.+?)\*"#, "$1")                   // italic *
        text = sub(text, #"(?<![A-Za-z0-9_])_([^_]+)_(?![A-Za-z0-9_])"#, "$1")  // italic _ (snake-safe)
        text = sub(text, #"`([^`]+)`"#, "$1")                   // inline code
        text = sub(text, #"(?m)^\s*([-*_])\1{2,}\s*$"#, "")     // horizontal rule
        return text
    }

    private static func sub(_ s: String, _ pattern: String, _ replacement: String) -> String {
        s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
}

// MARK: - Tools

public struct SlugifyTool: OrchestratorTool {
    public init() {}
    public let name = "slugify"
    public let toolDescription = "Turn text into a URL/filename-safe slug (\"My Great Note!\" → my-great-note)."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "text": ["type": "string", "description": "The text to slugify."],
    ], "required": ["text"]] }
    public func invoke(arguments: String) async -> String {
        guard let text = JSONArgs(arguments).string("text"), !text.isEmpty else { return "Missing 'text'." }
        let slug = Slugifier.slugify(text)
        guard !slug.isEmpty else { return "'\(text)' has no slug-able characters (try a title with letters/digits)." }
        return slug
    }
}

public struct FormatListTool: OrchestratorTool {
    public init() {}
    public let name = "format_list"
    public let toolDescription = "Reformat a newline-separated list as numbered, bullet, comma, or an Oxford-comma sentence ('and')."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "text": ["type": "string", "description": "Items, one per line."],
        "style": ["type": "string", "description": "numbered | bullet | comma | and"],
    ], "required": ["text", "style"]] }
    public func invoke(arguments: String) async -> String {
        let a = JSONArgs(arguments)
        guard let text = a.string("text"), !text.isEmpty else { return "Missing 'text'." }
        guard let style = a.string("style"), let out = ListFormatter.format(text, style: style) else {
            return "Couldn't format the list. Use style 'numbered', 'bullet', 'comma', or 'and', with items one per line."
        }
        return out
    }
}

public struct MakeChecklistTool: OrchestratorTool {
    public init() {}
    public let name = "make_checklist"
    public let toolDescription = "Turn a list of lines into a markdown checklist (- [ ] items), preserving any [x] done-state."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "data": ["type": "string", "description": "Items, one per line."],
    ], "required": ["data"]] }
    public func invoke(arguments: String) async -> String {
        guard let data = JSONArgs(arguments).string("data"), !data.isEmpty else { return "Missing 'data' (a list of items)." }
        guard let checklist = ChecklistBuilder.build(data) else { return "No items to turn into a checklist. Pass items one per line." }
        return checklist
    }
}

public struct StripMarkdownTool: OrchestratorTool {
    public init() {}
    public let name = "strip_markdown"
    public let toolDescription = "Strip markdown formatting to plain text (headings, bold/italic, links, code, bullets)."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "text": ["type": "string", "description": "Markdown text."],
    ], "required": ["text"]] }
    public func invoke(arguments: String) async -> String {
        guard let text = JSONArgs(arguments).string("text"), !text.isEmpty else { return "Missing 'text'." }
        return MarkdownStripper.strip(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum TextFormatTools {
    /// The generic text-presentation tools, ready to add to `Orchestrator.run`.
    public static func all() -> [OrchestratorTool] {
        [SlugifyTool(), FormatListTool(), MakeChecklistTool(), StripMarkdownTool()]
    }
}
