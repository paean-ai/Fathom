import Foundation

/// Generic validation tools for the SDK — Luhn checksum (cards/IMEIs/IDs), email well-formedness,
/// and password-strength estimation (entropy, on-device). Self-contained pure helpers + thin
/// `OrchestratorTool` wrappers. Pure → unit-testable.

public enum Luhn {
    /// True when the digits of `s` (spaces/dashes ignored) pass the Luhn checksum.
    public static func isValid(_ s: String) -> Bool {
        let digits = s.compactMap { $0.wholeNumberValue }
        guard digits.count >= 2 else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 { let dd = d * 2; sum += dd > 9 ? dd - 9 : dd } else { sum += d }
        }
        return sum % 10 == 0
    }
}

public enum Email {
    /// True when `s` is a well-formed `local@domain.tld` address (whole-string match, trimmed).
    public static func isValid(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains(" ") else { return false }
        let pattern = "^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$"
        return t.range(of: pattern, options: .regularExpression) != nil
    }
}

public enum PasswordStrength {
    public struct Result: Equatable {
        public let bits: Double
        public let label: String
        public let poolSize: Int
    }

    /// Entropy estimate ≈ length × log2(pool), pool by character class used. nil for empty.
    public static func evaluate(_ password: String) -> Result? {
        guard !password.isEmpty else { return nil }
        var pool = 0
        if password.contains(where: { $0.isLowercase && $0.isLetter }) { pool += 26 }
        if password.contains(where: { $0.isUppercase && $0.isLetter }) { pool += 26 }
        if password.contains(where: { $0.isNumber }) { pool += 10 }
        if password.contains(where: { !$0.isLetter && !$0.isNumber }) { pool += 32 }
        pool = Swift.max(pool, 1)
        let bits = Double(password.count) * log2(Double(pool))
        return Result(bits: bits, label: label(for: bits), poolSize: pool)
    }

    private static func label(for bits: Double) -> String {
        switch bits {
        case ..<28:  return "very weak"
        case ..<36:  return "weak"
        case ..<60:  return "reasonable"
        case ..<128: return "strong"
        default:     return "very strong"
        }
    }
}

// MARK: - Tools

public struct LuhnTool: OrchestratorTool {
    public init() {}
    public let name = "luhn"
    public let toolDescription = "Check whether a number passes the Luhn checksum (credit cards, IMEIs, many IDs). Spaces and dashes ignored."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "value": ["type": "string", "description": "The number to validate."],
    ], "required": ["value"]] }
    public func invoke(arguments: String) async -> String {
        guard let v = JSONArgs(arguments).string("value"), !v.isEmpty else { return "Error: missing 'value'." }
        return "\(v) is \(Luhn.isValid(v) ? "valid" : "invalid") (Luhn checksum)."
    }
}

public struct EmailValidatorTool: OrchestratorTool {
    public init() {}
    public let name = "validate_email"
    public let toolDescription = "Check whether a string is a well-formed email address (local@domain.tld)."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "email": ["type": "string", "description": "The address to validate."],
    ], "required": ["email"]] }
    public func invoke(arguments: String) async -> String {
        guard let e = JSONArgs(arguments).string("email"), !e.isEmpty else { return "Error: missing 'email'." }
        return "'\(e)' is \(Email.isValid(e) ? "a valid" : "not a valid") email address."
    }
}

public struct PasswordStrengthTool: OrchestratorTool {
    public init() {}
    public let name = "password_strength"
    public let toolDescription = "Estimate a password's strength on-device — entropy bits + a label (very weak…very strong). Never sent anywhere."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "password": ["type": "string", "description": "The password to evaluate."],
    ], "required": ["password"]] }
    public func invoke(arguments: String) async -> String {
        guard let pw = JSONArgs(arguments).string("password"), !pw.isEmpty else { return "Error: missing 'password'." }
        guard let r = PasswordStrength.evaluate(pw) else { return "Nothing to evaluate." }
        return "\(Int(r.bits.rounded())) bits of entropy — \(r.label) (\(pw.count) chars, pool \(r.poolSize))."
    }
}

public enum ValidationTools {
    /// The generic validation tools, ready to add to `Orchestrator.run`.
    public static func all() -> [OrchestratorTool] { [LuhnTool(), EmailValidatorTool(), PasswordStrengthTool()] }
}
