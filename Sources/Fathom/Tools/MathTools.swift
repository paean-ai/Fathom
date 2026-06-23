import Foundation

/// Generic number/math tools for the SDK — Roman numerals, ordinals, base conversion, GCD/LCM,
/// prime factorization, and thousands grouping. Self-contained pure helpers + thin
/// `OrchestratorTool` wrappers. Pure → unit-testable.

public enum RomanNumeral {
    private static let table: [(Int, String)] = [
        (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
        (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
    ]
    private static let values: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000]

    /// Arabic → Roman (1…3999). nil out of range.
    public static func toRoman(_ n: Int) -> String? {
        guard n >= 1, n <= 3999 else { return nil }
        var n = n, out = ""
        for (v, r) in table { while n >= v { out += r; n -= v } }
        return out
    }

    /// Roman → Arabic. nil if it contains a non-Roman character or doesn't re-encode to itself
    /// (rejects malformed numerals like "IIII" or "VX").
    public static func fromRoman(_ s: String) -> Int? {
        let up = s.uppercased()
        guard !up.isEmpty, up.allSatisfy({ values[$0] != nil }) else { return nil }
        var total = 0, prev = 0
        for ch in up.reversed() {
            let v = values[ch]!
            total += v < prev ? -v : v
            prev = v
        }
        return toRoman(total) == up ? total : nil
    }

    /// Auto-detect direction: a number → Roman, a Roman numeral → number.
    public static func convert(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let n = Int(t) { return toRoman(n) }
        if let n = fromRoman(t) { return String(n) }
        return nil
    }
}

public enum Ordinal {
    /// 1 → "1st", 2 → "2nd", 11 → "11th", 23 → "23rd", -1 → "-1st".
    public static func format(_ n: Int) -> String {
        let a = abs(n) % 100
        let suffix: String
        if (11...13).contains(a) { suffix = "th" }
        else { switch a % 10 { case 1: suffix = "st"; case 2: suffix = "nd"; case 3: suffix = "rd"; default: suffix = "th" } }
        return "\(n)\(suffix)"
    }
}

public enum BaseConvert {
    /// Convert `value` (in base `from`) to base `to`. Bases 2…36; nil on invalid input/base.
    public static func convert(_ value: String, from: Int, to: Int) -> String? {
        guard (2...36).contains(from), (2...36).contains(to) else { return nil }
        let v = value.trimmingCharacters(in: .whitespaces)
        let negative = v.hasPrefix("-")
        let digits = negative ? String(v.dropFirst()) : v
        guard !digits.isEmpty, let n = Int(digits, radix: from) else { return nil }
        let s = String(n, radix: to).uppercased()
        return negative && n != 0 ? "-\(s)" : s
    }
}

public enum IntMath {
    public static func gcd(_ a: Int, _ b: Int) -> Int { var a = abs(a), b = abs(b); while b != 0 { (a, b) = (b, a % b) }; return a }
    public static func lcm(_ a: Int, _ b: Int) -> Int { (a == 0 || b == 0) ? 0 : abs(a / gcd(a, b) * b) }

    public static func isPrime(_ n: Int) -> Bool {
        if n < 2 { return false }
        if n < 4 { return true }
        if n % 2 == 0 || n % 3 == 0 { return false }
        var i = 5
        while i * i <= n { if n % i == 0 || n % (i + 2) == 0 { return false }; i += 6 }
        return true
    }

    /// Ascending prime factors (with multiplicity). [] for n < 2.
    public static func factorize(_ n: Int) -> [Int] {
        guard n >= 2 else { return [] }
        var n = n, out: [Int] = []
        var d = 2
        while d * d <= n { while n % d == 0 { out.append(d); n /= d }; d += d == 2 ? 1 : 2 }
        if n > 1 { out.append(n) }
        return out
    }

    /// Thousands-grouped integer (locale-independent): 1234567 → "1,234,567".
    public static func grouped(_ n: Int) -> String {
        let s = String(abs(n))
        var out = "", count = 0
        for ch in s.reversed() { if count != 0 && count % 3 == 0 { out.append(",") }; out.append(ch); count += 1 }
        return (n < 0 ? "-" : "") + String(out.reversed())
    }
}

// MARK: - Tools

public struct RomanTool: OrchestratorTool {
    public init() {}
    public let name = "roman_numeral"
    public let toolDescription = "Convert between Arabic and Roman numerals (1–3999), direction auto-detected."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "value": ["type": "string", "description": "A number (1–3999) or a Roman numeral."],
    ], "required": ["value"]] }
    public func invoke(arguments: String) async -> String {
        guard let v = JSONArgs(arguments).string("value"), !v.isEmpty else { return "Error: missing 'value'." }
        guard let out = RomanNumeral.convert(v) else { return "Couldn't convert '\(v)' — use a number 1–3999 or a valid Roman numeral." }
        return "\(v) = \(out)"
    }
}

public struct OrdinalTool: OrchestratorTool {
    public init() {}
    public let name = "ordinal"
    public let toolDescription = "Format an integer as an ordinal (1 → 1st, 22 → 22nd, 113 → 113th)."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "value": ["type": "string", "description": "An integer."],
    ], "required": ["value"]] }
    public func invoke(arguments: String) async -> String {
        guard let v = JSONArgs(arguments).string("value"), let n = Int(v.trimmingCharacters(in: .whitespaces)) else { return "Need an integer 'value'." }
        return Ordinal.format(n)
    }
}

public struct BaseConvertTool: OrchestratorTool {
    public init() {}
    public let name = "convert_base"
    public let toolDescription = "Convert a number between bases (2–36). Set 'value', 'from', and 'to'."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "value": ["type": "string", "description": "The number, in base 'from'."],
        "from": ["type": "string", "description": "Source base (2–36)."],
        "to": ["type": "string", "description": "Target base (2–36)."],
    ], "required": ["value", "from", "to"]] }
    public func invoke(arguments: String) async -> String {
        let a = JSONArgs(arguments)
        guard let value = a.string("value"), let from = Int(a.string("from") ?? ""), let to = Int(a.string("to") ?? "") else {
            return "Need 'value' and integer 'from'/'to' bases."
        }
        guard let out = BaseConvert.convert(value, from: from, to: to) else {
            return "Couldn't convert — bases must be 2–36 and '\(value)' valid in base \(from)."
        }
        return "\(value) (base \(from)) = \(out) (base \(to))"
    }
}

public struct GCDTool: OrchestratorTool {
    public init() {}
    public let name = "gcd_lcm"
    public let toolDescription = "Greatest common divisor and least common multiple of two integers 'a' and 'b'."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "a": ["type": "string", "description": "First integer."],
        "b": ["type": "string", "description": "Second integer."],
    ], "required": ["a", "b"]] }
    public func invoke(arguments: String) async -> String {
        let args = JSONArgs(arguments)
        guard let a = Int(args.string("a") ?? ""), let b = Int(args.string("b") ?? "") else { return "Need integer 'a' and 'b'." }
        return "gcd(\(a), \(b)) = \(IntMath.gcd(a, b)), lcm = \(IntMath.lcm(a, b))"
    }
}

public struct FactorizeTool: OrchestratorTool {
    public init() {}
    public let name = "factorize"
    public let toolDescription = "Tell whether a number is prime, or give its prime factorization (e.g. 60 → 2 × 2 × 3 × 5)."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "value": ["type": "string", "description": "An integer ≥ 2."],
    ], "required": ["value"]] }
    public func invoke(arguments: String) async -> String {
        guard let n = Int(JSONArgs(arguments).string("value") ?? "") else { return "Need an integer 'value'." }
        guard n >= 2, n <= 1_000_000_000_000 else { return "Give an integer between 2 and 1,000,000,000,000." }
        if IntMath.isPrime(n) { return "\(n) is prime." }
        return "\(n) = \(IntMath.factorize(n).map(String.init).joined(separator: " × "))"
    }
}

public enum MathTools {
    /// The generic number/math tools, ready to add to `Orchestrator.run`.
    public static func all() -> [OrchestratorTool] {
        [RomanTool(), OrdinalTool(), BaseConvertTool(), GCDTool(), FactorizeTool()]
    }
}
