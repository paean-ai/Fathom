import Foundation

/// More generic text utilities for the SDK — palindrome & anagram checks, truncation, headline
/// (title) casing, and acronym building. Self-contained pure helpers + thin `OrchestratorTool`
/// wrappers. Complements `TextTransform`/`Base64` in TextTools.swift. Pure → unit-testable.

public enum TextCheck {
    /// True when `text` reads the same forwards and backwards, ignoring case and non-alphanumerics.
    public static func isPalindrome(_ text: String) -> Bool {
        let cleaned = text.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !cleaned.isEmpty else { return false }
        return cleaned == String(cleaned.reversed())
    }

    /// Sorted lowercase letter/digit signature — two strings are anagrams iff signatures match.
    public static func signature(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber }.sorted())
    }

    /// True when both phrases use the same multiset of letters/digits. Empty/punctuation-only → false.
    public static func isAnagram(_ a: String, _ b: String) -> Bool {
        let sa = signature(a)
        return !sa.isEmpty && sa == signature(b)
    }
}

public enum TextTruncate {
    /// Truncate to at most `n` characters, appending "…" when shortened (n ≥ 1).
    public static func toChars(_ text: String, _ n: Int) -> String {
        guard n >= 1, text.count > n else { return text }
        return String(text.prefix(n)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Truncate to at most `n` whitespace-separated words, appending "…" when shortened.
    public static func toWords(_ text: String, _ n: Int) -> String {
        let words = text.split { $0.isWhitespace }
        guard n >= 1, words.count > n else { return text }
        return words.prefix(n).joined(separator: " ") + "…"
    }
}

public enum HeadlineCase {
    private static let minor: Set<String> = ["a", "an", "and", "as", "at", "but", "by", "for", "if",
                                             "in", "nor", "of", "on", "or", "the", "to", "vs", "via"]
    /// Title-case a headline: capitalize each word except minor words (unless first/last).
    public static func titleize(_ text: String) -> String {
        let words = text.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return text }
        return words.enumerated().map { i, w in
            let isEdge = i == 0 || i == words.count - 1
            if !isEdge && minor.contains(w) { return w }
            return w.prefix(1).uppercased() + w.dropFirst()
        }.joined(separator: " ")
    }
}

public enum Acronym {
    private static let minor: Set<String> = ["a", "an", "and", "of", "the", "for", "to", "in", "on", "or"]
    /// First letter of each word, uppercased. `skipMinor` drops articles/conjunctions.
    public static func make(_ phrase: String, skipMinor: Bool = false) -> String {
        phrase.split { !$0.isLetter && !$0.isNumber }
            .filter { !skipMinor || !minor.contains($0.lowercased()) }
            .compactMap { $0.first }
            .map { String($0).uppercased() }
            .joined()
    }
}

// MARK: - Tools

public struct PalindromeTool: OrchestratorTool {
    public init() {}
    public let name = "palindrome"
    public let toolDescription = "Check whether text reads the same forwards and backwards (ignoring case and punctuation)."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "text": ["type": "string", "description": "The text to check."],
    ], "required": ["text"]] }
    public func invoke(arguments: String) async -> String {
        guard let text = JSONArgs(arguments).string("text"), !text.isEmpty else { return "Error: missing 'text'." }
        return "'\(text)' is \(TextCheck.isPalindrome(text) ? "a palindrome" : "not a palindrome")."
    }
}

public struct AnagramTool: OrchestratorTool {
    public init() {}
    public let name = "anagram"
    public let toolDescription = "Check whether two phrases are anagrams (same letters rearranged; case/spaces/punctuation ignored)."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "a": ["type": "string", "description": "First phrase."],
        "b": ["type": "string", "description": "Second phrase."],
    ], "required": ["a", "b"]] }
    public func invoke(arguments: String) async -> String {
        let args = JSONArgs(arguments)
        guard let a = args.string("a"), let b = args.string("b") else { return "Need two phrases 'a' and 'b'." }
        return "'\(a)' and '\(b)' are \(TextCheck.isAnagram(a, b) ? "anagrams" : "NOT anagrams")."
    }
}

public struct TruncateTool: OrchestratorTool {
    public init() {}
    public let name = "truncate"
    public let toolDescription = "Truncate text to a length. mode 'chars' (default) or 'words'; set 'length'."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "text": ["type": "string", "description": "The text to truncate."],
        "length": ["type": "string", "description": "Max characters (or words)."],
        "mode": ["type": "string", "description": "'chars' (default) or 'words'."],
    ], "required": ["text", "length"]] }
    public func invoke(arguments: String) async -> String {
        let a = JSONArgs(arguments)
        guard let text = a.string("text"), let n = Int(a.string("length") ?? ""), n > 0 else { return "Need 'text' and a positive 'length'." }
        return (a.string("mode") ?? "chars").lowercased() == "words" ? TextTruncate.toWords(text, n) : TextTruncate.toChars(text, n)
    }
}

public struct HeadlineCaseTool: OrchestratorTool {
    public init() {}
    public let name = "headline_case"
    public let toolDescription = "Title-case a headline (capitalize each word except minor words like a/the/of)."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "text": ["type": "string", "description": "The headline text."],
    ], "required": ["text"]] }
    public func invoke(arguments: String) async -> String {
        guard let text = JSONArgs(arguments).string("text"), !text.isEmpty else { return "Error: missing 'text'." }
        return HeadlineCase.titleize(text)
    }
}

public struct AcronymTool: OrchestratorTool {
    public init() {}
    public let name = "acronym"
    public let toolDescription = "Make an acronym from a phrase (first letter of each word). Set skip_minor=true to drop a/the/of/etc."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "phrase": ["type": "string", "description": "The phrase to acronymize."],
        "skip_minor": ["type": "string", "description": "true to skip minor words (default false)."],
    ], "required": ["phrase"]] }
    public func invoke(arguments: String) async -> String {
        let a = JSONArgs(arguments)
        guard let phrase = a.string("phrase"), !phrase.isEmpty else { return "Error: missing 'phrase'." }
        let acr = Acronym.make(phrase, skipMinor: (a.string("skip_minor") ?? "false").lowercased() == "true")
        return acr.isEmpty ? "No letters to acronymize in '\(phrase)'." : "\(phrase) → \(acr)"
    }
}

public enum TextUtils {
    /// The extra text-utility tools, ready to add to `Orchestrator.run`.
    public static func all() -> [OrchestratorTool] {
        [PalindromeTool(), AnagramTool(), TruncateTool(), HeadlineCaseTool(), AcronymTool()]
    }
}
