import Foundation

/// Generic unit-conversion / humanization tools for the SDK — temperature (C/F/K), byte sizes
/// (decimal, like Finder), and durations (seconds ↔ "1h 30m"). Self-contained pure helpers + thin
/// `OrchestratorTool` wrappers. Pure → unit-testable.

public enum Temperature {
    /// Convert `value` between C/F/K. nil if a unit isn't C, F, or K.
    public static func convert(_ value: Double, from: String, to: String) -> Double? {
        func toC(_ v: Double, _ u: String) -> Double? {
            switch u.uppercased().first { case "C": return v; case "F": return (v - 32) * 5 / 9; case "K": return v - 273.15; default: return nil }
        }
        func fromC(_ c: Double, _ u: String) -> Double? {
            switch u.uppercased().first { case "C": return c; case "F": return c * 9 / 5 + 32; case "K": return c + 273.15; default: return nil }
        }
        guard let c = toC(value, from), let r = fromC(c, to) else { return nil }
        return r
    }
    /// Trim trailing zeros for display.
    public static func fmt(_ v: Double) -> String {
        if v == v.rounded() { return String(Int(v)) }
        return String(format: "%.2f", v).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression).replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }
}

public enum ByteSize {
    private static let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]
    /// Humanize a byte count (decimal, 1000-based, like Finder): 1500000 → "1.5 MB".
    public static func humanize(_ bytes: Int) -> String {
        guard bytes != 0 else { return "0 bytes" }
        var v = Double(abs(bytes)), i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        let s = i == 0 ? String(Int(v)) : String(format: "%.2f", v).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression).replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
        return "\(bytes < 0 ? "-" : "")\(s) \(units[i])"
    }
    /// Parse a size like "1.5 MB" / "2GB" into bytes. nil if unparseable.
    public static func parse(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces).uppercased()
        let factors: [(String, Double)] = [("PB", 1e15), ("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3), ("B", 1)]
        for (suffix, factor) in factors where t.hasSuffix(suffix) {
            let num = t.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            if let v = Double(num) { return Int(v * factor) }
        }
        return Double(t).map { Int($0) }
    }
}

public enum HumanDuration {
    /// Humanize seconds → "1h 1m 1s" (largest non-zero units). 0 → "0s".
    public static func humanize(_ seconds: Int) -> String {
        guard seconds != 0 else { return "0s" }
        let neg = seconds < 0
        var s = abs(seconds)
        var parts: [String] = []
        let units: [(String, Int)] = [("d", 86400), ("h", 3600), ("m", 60), ("s", 1)]
        for (label, size) in units where s >= size { parts.append("\(s / size)\(label)"); s %= size }
        return (neg ? "-" : "") + parts.joined(separator: " ")
    }
    /// Parse "1h 30m", "90", or "1:30:00" into seconds. nil if unparseable.
    public static func parse(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.contains(":") {
            let parts = t.split(separator: ":").map { Int($0) }
            guard parts.allSatisfy({ $0 != nil }) else { return nil }
            return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        }
        if let n = Int(t) { return n }
        var total = 0, found = false
        let units: [(Character, Int)] = [("d", 86400), ("h", 3600), ("m", 60), ("s", 1)]
        for (label, size) in units {
            if let r = t.range(of: #"(\d+)\s*"# + String(label), options: .regularExpression) {
                let digits = t[r].filter(\.isNumber)
                if let v = Int(digits) { total += v * size; found = true }
            }
        }
        return found ? total : nil
    }
}

// MARK: - Tools

public struct TemperatureTool: OrchestratorTool {
    public init() {}
    public let name = "temperature"
    public let toolDescription = "Convert a temperature between C, F, and K. Set 'value', 'from', and 'to'."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "value": ["type": "string", "description": "The temperature value."],
        "from": ["type": "string", "description": "Source unit (C, F, or K)."],
        "to": ["type": "string", "description": "Target unit (C, F, or K)."],
    ], "required": ["value", "from", "to"]] }
    public func invoke(arguments: String) async -> String {
        let a = JSONArgs(arguments)
        guard let value = Double(a.string("value") ?? ""), let from = a.string("from"), let to = a.string("to") else { return "Need numeric 'value' and 'from'/'to' units (C, F, or K)." }
        guard let r = Temperature.convert(value, from: from, to: to) else { return "Units must be C, F, or K." }
        return "\(Temperature.fmt(value))° \(from.uppercased().prefix(1)) = \(Temperature.fmt(r))° \(to.uppercased().prefix(1))"
    }
}

public struct FileSizeTool: OrchestratorTool {
    public init() {}
    public let name = "file_size"
    public let toolDescription = "Convert between a byte count and a human-readable size (decimal). '1500000' → '1.5 MB', or '1.5 MB' → bytes."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "value": ["type": "string", "description": "Bytes (e.g. '1500000') or a size ('1.5 MB')."],
    ], "required": ["value"]] }
    public func invoke(arguments: String) async -> String {
        guard let v = JSONArgs(arguments).string("value"), !v.isEmpty else { return "Error: missing 'value'." }
        if let bytes = Int(v.trimmingCharacters(in: .whitespaces)) { return "\(bytes) bytes = \(ByteSize.humanize(bytes))" }
        guard let bytes = ByteSize.parse(v) else { return "Couldn't parse '\(v)' — use bytes or a size like '1.5 MB'." }
        return "\(v) = \(bytes) bytes"
    }
}

public struct DurationTool: OrchestratorTool {
    public init() {}
    public let name = "duration"
    public let toolDescription = "Convert between seconds and human-readable durations. A number → '1h 1m 1s'; '1h 30m' or '1:30:00' → seconds."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "value": ["type": "string", "description": "Seconds, or a duration like '1h 30m' / '1:30:00'."],
    ], "required": ["value"]] }
    public func invoke(arguments: String) async -> String {
        guard let v = JSONArgs(arguments).string("value"), !v.isEmpty else { return "Error: missing 'value'." }
        if let secs = Int(v.trimmingCharacters(in: .whitespaces)) { return "\(secs) seconds = \(HumanDuration.humanize(secs))" }
        guard let secs = HumanDuration.parse(v) else { return "Couldn't parse '\(v)' — use seconds, '1h 30m', or '1:30:00'." }
        return "\(v) = \(secs) seconds (\(HumanDuration.humanize(secs)))"
    }
}

public enum UnitTools {
    /// The generic unit-conversion tools, ready to add to `Orchestrator.run`.
    public static func all() -> [OrchestratorTool] { [TemperatureTool(), FileSizeTool(), DurationTool()] }
}
