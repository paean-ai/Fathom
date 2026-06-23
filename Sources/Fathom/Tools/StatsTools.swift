import Foundation

/// Generic numeric/statistics tools for the SDK — parse a list of numbers and summarize it,
/// compute quartiles, or an arbitrary percentile. Self-contained (pure static logic + a thin
/// `OrchestratorTool` wrapper each), so any Fathom agent gets them without a host re-implementing
/// the math. This is where an app's number tools migrate. Pure helpers → unit-testable.
public enum Numbers {
    /// Parse a free-form list of numbers (comma/space/newline/semicolon separated).
    public static func parse(_ s: String) -> [Double] {
        s.split { $0 == "," || $0 == ";" || $0 == "\n" || $0 == "\t" || $0 == " " }
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    public static func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }

    /// Median of a list (averages the middle pair for even counts). 0 for empty.
    public static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted(); let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// Population standard deviation.
    public static func stdev(_ xs: [Double]) -> Double {
        guard xs.count > 0 else { return 0 }
        let m = mean(xs)
        return (xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count)).squareRoot()
    }

    /// Quartiles via the exclusive method (median excluded from each half for odd counts).
    public static func quartiles(_ xs: [Double]) -> (q1: Double, q2: Double, q3: Double, iqr: Double)? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted(); let half = s.count / 2
        let q2 = median(s)
        let q1 = half == 0 ? q2 : median(Array(s.prefix(half)))
        let q3 = half == 0 ? q2 : median(Array(s.suffix(half)))
        return (q1, q2, q3, q3 - q1)
    }

    /// The `p`-th percentile (0…100, clamped) via linear interpolation between closest ranks
    /// (NumPy's default). nil for an empty list.
    public static func percentile(_ xs: [Double], _ p: Double) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        if s.count == 1 { return s[0] }
        let pct = Swift.max(0, Swift.min(100, p))
        let rank = pct / 100 * Double(s.count - 1)
        let lo = Int(rank.rounded(.down)), hi = Int(rank.rounded(.up))
        if lo == hi { return s[lo] }
        return s[lo] + (rank - Double(lo)) * (s[hi] - s[lo])
    }

    /// Compact, locale-independent number formatting (drop trailing zeros).
    public static func fmt(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 { return String(Int(v)) }
        var s = String(format: "%.4f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

public struct NumberStatsTool: OrchestratorTool {
    public init() {}
    public let name = "number_stats"
    public let toolDescription = "Summary statistics of a list of numbers: count, sum, mean, median, min, max, and standard deviation."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "data": ["type": "string", "description": "Numbers separated by commas/spaces/newlines."],
    ], "required": ["data"]] }
    public func invoke(arguments: String) async -> String {
        let xs = Numbers.parse(JSONArgs(arguments).string("data") ?? "")
        guard !xs.isEmpty else { return "No numbers found in the data." }
        let f = Numbers.fmt
        return "n=\(xs.count), sum \(f(xs.reduce(0, +))), mean \(f(Numbers.mean(xs))), median \(f(Numbers.median(xs))), min \(f(xs.min()!)), max \(f(xs.max()!)), stdev \(f(Numbers.stdev(xs)))"
    }
}

public struct QuartilesTool: OrchestratorTool {
    public init() {}
    public let name = "quartiles"
    public let toolDescription = "Quartiles of a list of numbers — Q1, median, Q3, and the interquartile range (IQR)."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "data": ["type": "string", "description": "Numbers separated by commas/spaces/newlines."],
    ], "required": ["data"]] }
    public func invoke(arguments: String) async -> String {
        let xs = Numbers.parse(JSONArgs(arguments).string("data") ?? "")
        guard let q = Numbers.quartiles(xs) else { return "No numbers found in the data." }
        let f = Numbers.fmt
        return "Q1 \(f(q.q1)), median \(f(q.q2)), Q3 \(f(q.q3)), IQR \(f(q.iqr))"
    }
}

public struct PercentileTool: OrchestratorTool {
    public init() {}
    public let name = "percentile"
    public let toolDescription = "The Nth percentile of a list of numbers (linear interpolation, like NumPy). Set 'p' (0–100, default 50)."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "data": ["type": "string", "description": "Numbers separated by commas/spaces/newlines."],
        "p": ["type": "string", "description": "Percentile 0–100 (default 50)."],
    ], "required": ["data"]] }
    public func invoke(arguments: String) async -> String {
        let a = JSONArgs(arguments)
        let xs = Numbers.parse(a.string("data") ?? "")
        let p = Double(a.string("p") ?? "") ?? 50
        guard let v = Numbers.percentile(xs, p) else { return "No numbers found in the data." }
        return "P\(Numbers.fmt(Swift.max(0, Swift.min(100, p)))) = \(Numbers.fmt(v)) (n=\(xs.count))"
    }
}

public enum StatsTools {
    /// The generic statistics tools, ready to add to `Orchestrator.run`.
    public static func all() -> [OrchestratorTool] { [NumberStatsTool(), QuartilesTool(), PercentileTool()] }
}
