import Foundation

// MARK: - General, app-agnostic tools any agent can use out of the box.

/// A small, safe arithmetic evaluator — exact math the model shouldn't do in its head.
/// Supports `+ - * / % ^` (right-assoc), parentheses, and unary `+/-`, with correct
/// precedence via recursive descent. No identifiers/functions, so nothing unsafe to
/// evaluate. Pure → unit-testable.
public enum Calculator {
    enum Tok: Equatable { case num(Double), op(Character), lp, rp }

    public static func eval(_ expr: String) -> Double? {
        guard let toks = tokenize(expr) else { return nil }
        var parser = Parser(toks)
        guard let v = parser.parseExpr(), parser.atEnd, v.isFinite else { return nil }
        return v
    }

    /// "3" not "3.0"; otherwise the natural decimal.
    public static func format(_ v: Double) -> String {
        if v.rounded() == v && abs(v) < 1e15 { return String(Int(v)) }
        return String(v)
    }

    static func tokenize(_ s: String) -> [Tok]? {
        var toks: [Tok] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\t" { i += 1; continue }
            if c.isNumber || c == "." {
                var num = ""
                while i < chars.count, chars[i].isNumber || chars[i] == "." { num.append(chars[i]); i += 1 }
                guard let d = Double(num) else { return nil }
                toks.append(.num(d)); continue
            }
            switch c {
            case "+", "-", "*", "/", "%", "^": toks.append(.op(c))
            case "(": toks.append(.lp)
            case ")": toks.append(.rp)
            default: return nil   // unknown character ⇒ not a valid expression
            }
            i += 1
        }
        return toks.isEmpty ? nil : toks
    }

    // expr := term (('+'|'-') term)*  ·  term := power (('*'|'/'|'%') power)*
    // power := unary ('^' power)?     ·  unary := ('+'|'-') unary | primary
    // primary := num | '(' expr ')'
    private struct Parser {
        let t: [Tok]; var i = 0
        init(_ t: [Tok]) { self.t = t }
        var atEnd: Bool { i >= t.count }
        func peek() -> Tok? { i < t.count ? t[i] : nil }

        mutating func parseExpr() -> Double? {
            guard var lhs = parseTerm() else { return nil }
            while case .op(let o)? = peek(), o == "+" || o == "-" {
                i += 1; guard let rhs = parseTerm() else { return nil }
                lhs = o == "+" ? lhs + rhs : lhs - rhs
            }
            return lhs
        }
        mutating func parseTerm() -> Double? {
            guard var lhs = parsePower() else { return nil }
            while case .op(let o)? = peek(), o == "*" || o == "/" || o == "%" {
                i += 1; guard let rhs = parsePower() else { return nil }
                if (o == "/" || o == "%") && rhs == 0 { return nil }   // no divide-by-zero
                lhs = o == "*" ? lhs * rhs : (o == "/" ? lhs / rhs : lhs.truncatingRemainder(dividingBy: rhs))
            }
            return lhs
        }
        mutating func parsePower() -> Double? {
            guard let base = parseUnary() else { return nil }
            if case .op("^")? = peek() {
                i += 1; guard let exp = parsePower() else { return nil }   // right-assoc
                return pow(base, exp)
            }
            return base
        }
        mutating func parseUnary() -> Double? {
            if case .op(let o)? = peek(), o == "+" || o == "-" {
                i += 1; guard let v = parseUnary() else { return nil }
                return o == "-" ? -v : v
            }
            return parsePrimary()
        }
        mutating func parsePrimary() -> Double? {
            switch peek() {
            case .num(let d): i += 1; return d
            case .lp:
                i += 1
                guard let v = parseExpr(), case .rp? = peek() else { return nil }
                i += 1; return v
            default: return nil
            }
        }
    }
}

/// Decode a single string field from a tool's raw JSON arguments.
func jsonString(_ argumentsJSON: String, _ key: String) -> String? {
    guard let data = argumentsJSON.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    if let s = obj[key] as? String { return s }
    if let n = obj[key] as? NSNumber { return n.stringValue }
    return nil
}

/// Built-in tool: evaluate arithmetic exactly. App-agnostic.
public struct CalculatorTool: OrchestratorTool {
    public init() {}
    public var name: String { "calculate" }
    public var toolDescription: String {
        "Evaluate an arithmetic expression EXACTLY (+ - * / % ^ and parentheses). Use this instead of doing math in your head."
    }
    public var parameters: [String: Any] {
        ["type": "object",
         "properties": ["expression": ["type": "string", "description": "e.g. (3 + 4) * 2 ^ 3"]],
         "required": ["expression"]]
    }
    public func invoke(arguments: String) async -> String {
        guard let expr = jsonString(arguments, "expression") else { return "Missing 'expression'." }
        guard let v = Calculator.eval(expr) else { return "Couldn't evaluate '\(expr)'." }
        return "\(expr.trimmingCharacters(in: .whitespaces)) = \(Calculator.format(v))"
    }
}

/// Built-in tool: the current date and time. `now` is injectable for deterministic tests.
public struct CurrentDateTimeTool: OrchestratorTool {
    private let now: @Sendable () -> Date
    public init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }
    public var name: String { "current_datetime" }
    public var toolDescription: String {
        "The current date and time (ISO-8601, in the device's time zone). Use when the user asks what day/time it is or for date math relative to now."
    }
    public var parameters: [String: Any] { ["type": "object", "properties": [:]] }
    public func invoke(arguments: String) async -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: now())
    }
}
