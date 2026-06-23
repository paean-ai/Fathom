import Foundation

/// Generic conversion / phonetic / analysis / visualization tools for the SDK — hex↔RGB color,
/// NATO phonetic spelling, letter-frequency analysis, and ASCII bar charts. Self-contained pure
/// helpers + thin `OrchestratorTool` wrappers. Pure → unit-testable.

/// Converts between hex and RGB colors ('#FF5733' ↔ 'rgb(255, 87, 51)'). Direction is
/// auto-detected (a comma means RGB input).
public enum ColorConvert {
    /// Parse '#FF5733' / 'FF5733' / '#fff' into (r, g, b); nil if not 3/6 hex digits.
    public static func hexToRGB(_ hex: String) -> (r: Int, g: Int, b: Int)? {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }   // expand shorthand
        guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
        return ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
    }

    /// '#RRGGBB' for 0–255 components; nil if any is out of range.
    public static func rgbToHex(_ r: Int, _ g: Int, _ b: Int) -> String? {
        guard [r, g, b].allSatisfy({ (0...255).contains($0) }) else { return nil }
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Auto-convert: a comma → RGB input → hex; otherwise hex input → rgb(). Nil if invalid.
    public static func describe(_ input: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespaces)
        if s.contains(",") {
            let nums = s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard nums.count == 3, let hex = rgbToHex(nums[0], nums[1], nums[2]) else { return nil }
            return "rgb(\(nums[0]), \(nums[1]), \(nums[2])) = \(hex)"
        }
        guard let (r, g, b) = hexToRGB(s), let hex = rgbToHex(r, g, b) else { return nil }
        return "\(hex) = rgb(\(r), \(g), \(b))"
    }
}

/// Spells text using the NATO phonetic alphabet — letters → Alfa/Bravo/…, digits → ICAO words,
/// space → "(space)". Unknown punctuation passes through verbatim. nil for empty input.
public enum NatoPhonetic {
    private static let letters: [Character: String] = [
        "a": "Alfa", "b": "Bravo", "c": "Charlie", "d": "Delta", "e": "Echo",
        "f": "Foxtrot", "g": "Golf", "h": "Hotel", "i": "India", "j": "Juliett",
        "k": "Kilo", "l": "Lima", "m": "Mike", "n": "November", "o": "Oscar",
        "p": "Papa", "q": "Quebec", "r": "Romeo", "s": "Sierra", "t": "Tango",
        "u": "Uniform", "v": "Victor", "w": "Whiskey", "x": "Xray", "y": "Yankee", "z": "Zulu",
    ]
    private static let digits: [Character: String] = [
        "0": "Zero", "1": "One", "2": "Two", "3": "Three", "4": "Four",
        "5": "Five", "6": "Six", "7": "Seven", "8": "Eight", "9": "Nine",
    ]

    public static func spell(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        var out: [String] = []
        for ch in text {
            if ch == " " {
                out.append("(space)")
            } else if let word = letters[Character(ch.lowercased())] {
                out.append(word)
            } else if let word = digits[ch] {
                out.append(word)
            } else {
                out.append(String(ch))
            }
        }
        return out.joined(separator: " ")
    }
}

/// Letter-frequency analysis — count how often each A–Z letter appears (case-insensitive), the
/// classic first step in breaking a substitution/Caesar/Vigenère cipher. Pairs with `Caesar`/`Vigenere`.
public enum CharFrequency {
    /// (letter, count, percent-of-letters) sorted by count descending, ties broken alphabetically.
    /// Empty when the text has no letters.
    public static func analyze(_ text: String) -> [(letter: Character, count: Int, percent: Double)] {
        var counts: [Character: Int] = [:]
        for ch in text.lowercased() where ch.isLetter && ch.isASCII {
            counts[ch, default: 0] += 1
        }
        let total = counts.values.reduce(0, +)
        guard total > 0 else { return [] }
        return counts
            .map { (letter: $0.key, count: $0.value, percent: Double($0.value) / Double(total) * 100) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.letter < $1.letter }
    }

    /// A compact text table of the top `limit` letters (default all), one per line.
    public static func table(_ rows: [(letter: Character, count: Int, percent: Double)], limit: Int = 26) -> String {
        rows.prefix(limit).map { r in
            "\(String(r.letter).uppercased())  \(r.count)  (\(String(format: "%.1f", r.percent))%)"
        }.joined(separator: "\n")
    }
}

/// Renders a horizontal ASCII bar chart — visualize numbers directly in chat. Input is "label:
/// value" pairs (comma- or newline-separated).
public enum AsciiChart {
    /// Parse "label: value" pairs (comma- or newline-separated). Invalid entries are skipped.
    public static func parse(_ data: String) -> [(label: String, value: Double)] {
        data.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .compactMap { piece -> (String, Double)? in
                guard let colon = piece.lastIndex(of: ":") else { return nil }
                let label = piece[..<colon].trimmingCharacters(in: .whitespaces)
                // Comma is the pair separator, so values can't carry a thousands separator.
                let raw = piece[piece.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard !label.isEmpty, let value = Double(raw) else { return nil }
                return (label, value)
            }
    }

    /// Render aligned bars scaled so the largest value fills `width` blocks.
    public static func bars(_ pairs: [(label: String, value: Double)], width: Int = 30) -> String {
        guard !pairs.isEmpty else { return "" }
        let labelWidth = pairs.map { $0.label.count }.max() ?? 0
        let maxValue = pairs.map { $0.value }.max() ?? 0
        return pairs.map { pair in
            let padded = pair.label.padding(toLength: labelWidth, withPad: " ", startingAt: 0)
            let n = maxValue > 0 ? Int((pair.value / maxValue * Double(width)).rounded()) : 0
            let bar = String(repeating: "█", count: max(0, n))
            return "\(padded) │\(bar) \(format(pair.value))"
        }.joined(separator: "\n")
    }

    public static func render(_ data: String, width: Int = 30) -> String? {
        let pairs = parse(data)
        guard !pairs.isEmpty else { return nil }
        return bars(pairs, width: width)
    }

    public static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }
}

// MARK: - Tools

public struct ColorTool: OrchestratorTool {
    public init() {}
    public let name = "color"
    public let toolDescription = "Convert a color between hex and RGB (#FF5733 ↔ rgb(255, 87, 51)), direction auto-detected."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "value": ["type": "string", "description": "A hex color (#RRGGBB/#RGB) or 'r, g, b' (0–255)."],
    ], "required": ["value"]] }
    public func invoke(arguments: String) async -> String {
        guard let v = JSONArgs(arguments).string("value"), !v.isEmpty else { return "Missing 'value'." }
        guard let out = ColorConvert.describe(v) else {
            return "Couldn't parse '\(v)' as a color — use #RRGGBB, #RGB, or 'r,g,b' (0–255)."
        }
        return out
    }
}

public struct NatoTool: OrchestratorTool {
    public init() {}
    public let name = "nato"
    public let toolDescription = "Spell text in the NATO phonetic alphabet (Cat → Charlie Alfa Tango)."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "text": ["type": "string", "description": "Text to spell out."],
    ], "required": ["text"]] }
    public func invoke(arguments: String) async -> String {
        guard let text = JSONArgs(arguments).string("text"), let spelled = NatoPhonetic.spell(text) else {
            return "Nothing to spell."
        }
        return spelled
    }
}

public struct CharFrequencyTool: OrchestratorTool {
    public init() {}
    public let name = "char_frequency"
    public let toolDescription = "Letter-frequency table for text (case-insensitive A–Z) — the first step in cipher analysis."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "text": ["type": "string", "description": "Text to analyze."],
        "top": ["type": "string", "description": "How many top letters to show (default 26)."],
    ], "required": ["text"]] }
    public func invoke(arguments: String) async -> String {
        let a = JSONArgs(arguments)
        guard let text = a.string("text"), !text.isEmpty else { return "Missing 'text'." }
        let rows = CharFrequency.analyze(text)
        guard !rows.isEmpty else { return "No A–Z letters to analyze." }
        let top = Int(a.string("top") ?? "") ?? 26
        return "```\n\(CharFrequency.table(rows, limit: top))\n```"
    }
}

public struct BarChartTool: OrchestratorTool {
    public init() {}
    public let name = "bar_chart"
    public let toolDescription = "Render a horizontal ASCII bar chart from 'label: value' pairs (comma- or newline-separated)."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "data": ["type": "string", "description": "'label: value' pairs, e.g. 'Jan: 8, Feb: 5'."],
    ], "required": ["data"]] }
    public func invoke(arguments: String) async -> String {
        guard let data = JSONArgs(arguments).string("data"), !data.isEmpty else { return "Missing 'data' (label: value pairs)." }
        guard let chart = AsciiChart.render(data) else {
            return "Couldn't parse any 'label: value' pairs from the data. Example: 'Jan: 8, Feb: 5'."
        }
        return "```\n\(chart)\n```"
    }
}

public enum InspectTools {
    /// The generic conversion/phonetic/analysis/visualization tools, ready to add to `Orchestrator.run`.
    public static func all() -> [OrchestratorTool] {
        [ColorTool(), NatoTool(), CharFrequencyTool(), BarChartTool()]
    }
}
