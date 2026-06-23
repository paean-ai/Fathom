import Foundation

/// Series / distribution statistics for the SDK — outliers (Tukey fences), z-scores, moving
/// average, running total, period-over-period % change, and Pearson correlation. Builds on
/// `Numbers` (parse/quartiles/mean/stdev/fmt). Self-contained pure logic + thin `OrchestratorTool`
/// wrappers. Pure helpers → unit-testable.
public enum Series {
    /// Tukey-fence outliers: below Q1−k·IQR or above Q3+k·IQR (k default 1.5). Needs ≥4 values
    /// and k>0, else nil. Returns the fences and the sorted low/high outliers.
    public static func outliers(_ xs: [Double], k: Double = 1.5)
        -> (lower: Double, upper: Double, low: [Double], high: [Double])? {
        guard xs.count >= 4, k > 0, let q = Numbers.quartiles(xs) else { return nil }
        let lo = q.q1 - k * q.iqr, hi = q.q3 + k * q.iqr
        let s = xs.sorted()
        return (lo, hi, s.filter { $0 < lo }, s.filter { $0 > hi })
    }

    /// z-score of `target` vs the population (mean/stdev) of `xs`. nil on empty or zero spread.
    public static func zScore(of target: Double, in xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let sd = Numbers.stdev(xs)
        return sd > 0 ? (target - Numbers.mean(xs)) / sd : nil
    }

    /// Simple moving average over a window (1…count); returns count−window+1 values, nil otherwise.
    public static func movingAverage(_ xs: [Double], window: Int) -> [Double]? {
        guard window >= 1, window <= xs.count else { return nil }
        var out: [Double] = [], sum = xs.prefix(window).reduce(0, +)
        out.append(sum / Double(window))
        for i in window..<xs.count { sum += xs[i] - xs[i - window]; out.append(sum / Double(window)) }
        return out
    }

    /// Cumulative running totals (same length as input).
    public static func runningTotal(_ xs: [Double]) -> [Double] {
        var s = 0.0; return xs.map { s += $0; return s }
    }

    /// Period-over-period % change (length n−1); nil where the prior value is 0.
    public static func pctChange(_ xs: [Double]) -> [Double?]? {
        guard xs.count >= 2 else { return nil }
        return (1..<xs.count).map { xs[$0 - 1] == 0 ? nil : (xs[$0] - xs[$0 - 1]) / xs[$0 - 1] * 100 }
    }

    /// Pearson correlation of two equal-length series. nil on length mismatch, <2 points, or a
    /// flat series. Clamped to [−1, 1].
    public static func correlation(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 2 else { return nil }
        let n = Double(x.count), mx = Numbers.mean(x), my = Numbers.mean(y)
        var cov = 0.0, vx = 0.0, vy = 0.0
        for i in 0..<x.count { let dx = x[i] - mx, dy = y[i] - my; cov += dx * dy; vx += dx * dx; vy += dy * dy }
        guard vx > 0, vy > 0 else { return nil }
        _ = n
        return Swift.max(-1, Swift.min(1, cov / (vx.squareRoot() * vy.squareRoot())))
    }
}

public struct OutliersTool: OrchestratorTool {
    public init() {}
    public let name = "outliers"
    public let toolDescription = "Detect outliers in a list of numbers using Tukey's IQR fences. Set 'k' (default 1.5; 3 = extreme-only). Needs ≥4 values."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "data": ["type": "string", "description": "Numbers separated by commas/spaces/newlines."],
        "k": ["type": "string", "description": "Fence multiplier (default 1.5)."],
    ], "required": ["data"]] }
    public func invoke(arguments: String) async -> String {
        let a = JSONArgs(arguments)
        let xs = Numbers.parse(a.string("data") ?? "")
        let k = Swift.max(Double(a.string("k") ?? "") ?? 1.5, 0.1)
        guard let r = Series.outliers(xs, k: k) else { return "Need at least 4 numbers to detect outliers." }
        let outs = r.low + r.high, f = Numbers.fmt
        if outs.isEmpty { return "No outliers (k=\(f(k)) fences \(f(r.lower))…\(f(r.upper)))." }
        return "\(outs.count) outlier\(outs.count == 1 ? "" : "s"): \(outs.map(f).joined(separator: ", ")) (outside \(f(r.lower))…\(f(r.upper)), k=\(f(k)))."
    }
}

public struct ZScoreTool: OrchestratorTool {
    public init() {}
    public let name = "z_score"
    public let toolDescription = "z-score of a value against a list of numbers (how many standard deviations from the mean). Pass 'value'."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "data": ["type": "string", "description": "Numbers separated by commas/spaces/newlines."],
        "value": ["type": "string", "description": "The number to score."],
    ], "required": ["data", "value"]] }
    public func invoke(arguments: String) async -> String {
        let a = JSONArgs(arguments)
        let xs = Numbers.parse(a.string("data") ?? "")
        guard let target = Double(a.string("value") ?? "") else { return "Need a numeric 'value'." }
        guard let z = Series.zScore(of: target, in: xs) else { return "Can't compute a z-score (empty or zero-spread data)." }
        return "z = \(Numbers.fmt((z * 1000).rounded() / 1000)) for \(Numbers.fmt(target)) (n=\(xs.count))"
    }
}

public struct CorrelationTool: OrchestratorTool {
    public init() {}
    public let name = "correlation"
    public let toolDescription = "Pearson correlation (r, −1…1) between two equal-length number lists 'x' and 'y'."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "x": ["type": "string", "description": "First series."],
        "y": ["type": "string", "description": "Second series (same length)."],
    ], "required": ["x", "y"]] }
    public func invoke(arguments: String) async -> String {
        let a = JSONArgs(arguments)
        let x = Numbers.parse(a.string("x") ?? ""), y = Numbers.parse(a.string("y") ?? "")
        guard x.count == y.count else { return "x has \(x.count) numbers but y has \(y.count) — lists must be the same length." }
        guard let r = Series.correlation(x, y) else { return "Need ≥2 paired numbers and neither list flat." }
        return "r = \(Numbers.fmt((r * 1000).rounded() / 1000)) (n=\(x.count))"
    }
}

public struct MovingAverageTool: OrchestratorTool {
    public init() {}
    public let name = "moving_average"
    public let toolDescription = "Rolling mean of a number series over a window (default 3) to reveal its trend."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "data": ["type": "string", "description": "Numbers separated by commas/spaces/newlines."],
        "window": ["type": "string", "description": "Window size (default 3)."],
    ], "required": ["data"]] }
    public func invoke(arguments: String) async -> String {
        let a = JSONArgs(arguments)
        let xs = Numbers.parse(a.string("data") ?? "")
        let w = Swift.max(Int(a.string("window") ?? "") ?? 3, 1)
        guard let ma = Series.movingAverage(xs, window: w) else { return "Window must be between 1 and the value count (\(xs.count))." }
        return "\(w)-point moving average: " + ma.map { Numbers.fmt(($0 * 100).rounded() / 100) }.joined(separator: ", ")
    }
}

public struct RunningTotalTool: OrchestratorTool {
    public init() {}
    public let name = "running_total"
    public let toolDescription = "Cumulative running totals of a number series (last = grand total)."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "data": ["type": "string", "description": "Numbers separated by commas/spaces/newlines."],
    ], "required": ["data"]] }
    public func invoke(arguments: String) async -> String {
        let xs = Numbers.parse(JSONArgs(arguments).string("data") ?? "")
        guard !xs.isEmpty else { return "No numbers found in the data." }
        let t = Series.runningTotal(xs)
        return "Running totals: " + t.map { Numbers.fmt(($0 * 100).rounded() / 100) }.joined(separator: ", ") + " — grand total \(Numbers.fmt(t.last!))"
    }
}

public struct PctChangeTool: OrchestratorTool {
    public init() {}
    public let name = "pct_change"
    public let toolDescription = "Period-over-period % change of a number series (n−1 values; a step after a zero is n/a)."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "data": ["type": "string", "description": "Numbers separated by commas/spaces/newlines."],
    ], "required": ["data"]] }
    public func invoke(arguments: String) async -> String {
        let xs = Numbers.parse(JSONArgs(arguments).string("data") ?? "")
        guard let changes = Series.pctChange(xs) else { return "Need at least 2 numbers." }
        let list = changes.map { c -> String in
            guard let c else { return "n/a" }
            return (c > 0 ? "+" : "") + Numbers.fmt((c * 100).rounded() / 100) + "%"
        }.joined(separator: ", ")
        return "Period-over-period change: \(list)"
    }
}

public enum SeriesTools {
    /// The series/distribution stat tools, ready to add to `Orchestrator.run`.
    public static func all() -> [OrchestratorTool] {
        [OutliersTool(), ZScoreTool(), CorrelationTool(), MovingAverageTool(), RunningTotalTool(), PctChangeTool()]
    }
}
