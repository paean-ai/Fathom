import Foundation

/// Generic number-presentation tools for the SDK — spell an integer in English words, add
/// thousands separators to a numeric string, and show an integer across decimal/hex/binary/octal.
/// Self-contained pure helpers + thin `OrchestratorTool` wrappers. Pure → unit-testable.

/// Spells an integer in English words — 1234 → "one thousand two hundred thirty-four". Handles
/// zero, negatives, and groups up to trillions; nil beyond that range.
public enum NumberWords {
    private static let ones = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
        "seventeen", "eighteen", "nineteen",
    ]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    private static let scales = ["", "thousand", "million", "billion", "trillion"]

    public static func spell(_ n: Int) -> String? {
        if n == 0 { return "zero" }
        var num = abs(n)
        var groups: [Int] = []
        while num > 0 { groups.append(num % 1000); num /= 1000 }
        guard groups.count <= scales.count else { return nil }   // beyond trillions

        var parts: [String] = []
        for i in stride(from: groups.count - 1, through: 0, by: -1) where groups[i] != 0 {
            var s = below1000(groups[i])
            if i > 0 { s += " " + scales[i] }
            parts.append(s)
        }
        let result = parts.joined(separator: " ")
        return n < 0 ? "negative " + result : result
    }

    private static func below1000(_ n: Int) -> String {
        var parts: [String] = []
        if n / 100 > 0 { parts.append(ones[n / 100] + " hundred") }
        let r = n % 100
        if r > 0 {
            if r < 20 {
                parts.append(ones[r])
            } else {
                let o = r % 10
                parts.append(o > 0 ? tens[r / 10] + "-" + ones[o] : tens[r / 10])
            }
        }
        return parts.joined(separator: " ")
    }
}

/// Adds thousands separators to a numeric string — '1234567.5' → '1,234,567.5'. Preserves sign and
/// any decimal part; existing commas are re-grouped. nil if the input isn't numeric.
public enum NumberFormat {
    public static func grouped(_ input: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        guard Double(s) != nil else { return nil }   // validate numeric

        var sign = ""
        var body = s
        if body.hasPrefix("-") { sign = "-"; body.removeFirst() }
        else if body.hasPrefix("+") { body.removeFirst() }

        let parts = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let intPart = String(parts[0])
        let decPart = parts.count > 1 ? "." + parts[1] : ""

        var grouped = ""
        var count = 0
        for ch in intPart.reversed() {
            if count > 0, count % 3 == 0 { grouped.append(",") }
            grouped.append(ch)
            count += 1
        }
        return sign + String(grouped.reversed()) + decPart
    }
}

/// Number-base inspection — show an integer in decimal, hex, binary, and octal at once.
/// Auto-detects the input base from a `0x`/`0b`/`0o` prefix (decimal otherwise).
public enum NumberBases {
    /// Parse an integer written in decimal or with a `0x`/`0b`/`0o` prefix; nil if invalid.
    public static func parse(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("0x") { return Int(t.dropFirst(2), radix: 16) }
        if t.hasPrefix("0b") { return Int(t.dropFirst(2), radix: 2) }
        if t.hasPrefix("0o") { return Int(t.dropFirst(2), radix: 8) }
        return Int(t)
    }

    public static func describe(_ s: String) -> String? {
        guard let n = parse(s) else { return nil }
        return "decimal \(n), hex \(prefixed(n, "0x", 16)), "
            + "binary \(prefixed(n, "0b", 2)), octal \(prefixed(n, "0o", 8))"
    }

    /// Render `n` in `radix` with `prefix`, keeping a leading minus for negatives.
    private static func prefixed(_ n: Int, _ prefix: String, _ radix: Int) -> String {
        n < 0 ? "-\(prefix)\(String(-n, radix: radix))" : "\(prefix)\(String(n, radix: radix))"
    }
}

// MARK: - Tools

public struct NumberToWordsTool: OrchestratorTool {
    public init() {}
    public let name = "number_to_words"
    public let toolDescription = "Spell an integer in English words (1234 → one thousand two hundred thirty-four)."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "value": ["type": "string", "description": "An integer (up to trillions)."],
    ], "required": ["value"]] }
    public func invoke(arguments: String) async -> String {
        guard let v = JSONArgs(arguments).string("value"), let n = Int(v.trimmingCharacters(in: .whitespaces)) else {
            return "Need an integer 'value'."
        }
        guard let words = NumberWords.spell(n) else { return "That number is too large to spell out." }
        return "\(n) = \(words)"
    }
}

public struct NumberFormatTool: OrchestratorTool {
    public init() {}
    public let name = "number_format"
    public let toolDescription = "Add thousands separators to a number (1234567 → 1,234,567), preserving sign and decimals."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "value": ["type": "string", "description": "A number, optionally signed/decimal."],
    ], "required": ["value"]] }
    public func invoke(arguments: String) async -> String {
        guard let v = JSONArgs(arguments).string("value"), !v.isEmpty else { return "Missing 'value'." }
        guard let out = NumberFormat.grouped(v) else { return "'\(v)' isn't a number." }
        return out
    }
}

public struct NumberBasesTool: OrchestratorTool {
    public init() {}
    public let name = "number_bases"
    public let toolDescription = "Show an integer in decimal, hex, binary, and octal at once. Accepts 0x/0b/0o-prefixed input."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "value": ["type": "string", "description": "An integer, decimal or 0x/0b/0o-prefixed."],
    ], "required": ["value"]] }
    public func invoke(arguments: String) async -> String {
        guard let v = JSONArgs(arguments).string("value"), !v.isEmpty else { return "Missing 'value'." }
        guard let out = NumberBases.describe(v) else { return "'\(v)' isn't a valid integer (try decimal or 0x/0b/0o-prefixed)." }
        return out
    }
}

public enum NumberFormatTools {
    /// The generic number-presentation tools, ready to add to `Orchestrator.run`.
    public static func all() -> [OrchestratorTool] {
        [NumberToWordsTool(), NumberFormatTool(), NumberBasesTool()]
    }
}
