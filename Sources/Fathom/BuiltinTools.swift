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

/// Converts a value between units of length, mass, or temperature. Pure + deterministic
/// → unit-testable. Length/mass use base-unit factors; temperature uses offset formulas.
/// Unknown or cross-dimension pairs return nil.
public enum UnitConvert {
    /// Factor to the base unit (length base = metre, mass base = gram).
    public static let length: [String: Double] = [
        "m": 1, "km": 1000, "cm": 0.01, "mm": 0.001, "um": 1e-6, "nm": 1e-9,
        "mi": 1609.344, "yd": 0.9144, "ft": 0.3048, "in": 0.0254,
    ]
    public static let mass: [String: Double] = [
        "g": 1, "kg": 1000, "mg": 0.001, "t": 1_000_000, "lb": 453.59237, "oz": 28.349523125,
    ]
    public static let temps: Set<String> = ["c", "f", "k"]

    /// Map many spellings/plurals to a canonical symbol, or nil if unrecognised.
    public static func canonical(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let alias: [String: String] = [
            "meter": "m", "metre": "m", "meters": "m", "metres": "m",
            "kilometer": "km", "kilometre": "km", "kilometers": "km", "kilometres": "km", "kms": "km",
            "centimeter": "cm", "centimetre": "cm", "centimeters": "cm",
            "millimeter": "mm", "millimetre": "mm", "millimeters": "mm",
            "micrometer": "um", "nanometer": "nm",
            "mile": "mi", "miles": "mi", "yard": "yd", "yards": "yd",
            "foot": "ft", "feet": "ft", "inch": "in", "inches": "in",
            "gram": "g", "grams": "g", "gramme": "g", "kilogram": "kg", "kilograms": "kg", "kilo": "kg", "kgs": "kg",
            "milligram": "mg", "milligrams": "mg", "tonne": "t", "tonnes": "t", "ton": "t",
            "pound": "lb", "pounds": "lb", "lbs": "lb", "ounce": "oz", "ounces": "oz",
            "celsius": "c", "centigrade": "c", "fahrenheit": "f", "kelvin": "k",
        ]
        if let a = alias[s] { return a }
        if length[s] != nil || mass[s] != nil || temps.contains(s) { return s }
        if s.hasSuffix("s"), case let trimmed = String(s.dropLast()),
           length[trimmed] != nil || mass[trimmed] != nil { s = trimmed; return s }
        return nil
    }

    public static func convert(_ value: Double, from rawFrom: String, to rawTo: String) -> Double? {
        guard let f = canonical(rawFrom), let t = canonical(rawTo) else { return nil }
        if let bf = length[f], let bt = length[t] { return value * bf / bt }
        if let bf = mass[f], let bt = mass[t] { return value * bf / bt }
        if temps.contains(f), temps.contains(t) { return convertTemp(value, from: f, to: t) }
        return nil   // unknown or cross-dimension (e.g. m → kg)
    }

    /// Temperature via celsius as the pivot.
    public static func convertTemp(_ v: Double, from f: String, to t: String) -> Double {
        let c: Double
        switch f { case "f": c = (v - 32) * 5 / 9; case "k": c = v - 273.15; default: c = v }
        switch t { case "f": return c * 9 / 5 + 32; case "k": return c + 273.15; default: return c }
    }
}

/// Built-in tool: convert between units of length, mass, or temperature.
public struct UnitConvertTool: OrchestratorTool {
    public init() {}
    public var name: String { "unit_convert" }
    public var toolDescription: String {
        "Convert a value between units of length, mass, or temperature (e.g. 10 km to mi, 72 f to c). Exact."
    }
    public var parameters: [String: Any] {
        ["type": "object",
         "properties": [
            "value": ["type": "number", "description": "the amount to convert"],
            "from": ["type": "string", "description": "source unit, e.g. km, lb, celsius"],
            "to": ["type": "string", "description": "target unit, e.g. mi, kg, fahrenheit"],
         ],
         "required": ["value", "from", "to"]]
    }
    public func invoke(arguments: String) async -> String {
        guard let vs = jsonString(arguments, "value"), let v = Double(vs),
              let from = jsonString(arguments, "from"), let to = jsonString(arguments, "to") else {
            return "Missing 'value', 'from', or 'to'."
        }
        guard let r = UnitConvert.convert(v, from: from, to: to) else {
            return "Can't convert '\(from)' to '\(to)' — unknown units or different dimensions."
        }
        return "\(Calculator.format(v)) \(from) = \(Calculator.format(r)) \(to)"
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
