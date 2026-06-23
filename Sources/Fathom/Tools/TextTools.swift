import Foundation

/// Generic text/encoding utility tools — the kind of small, universal capabilities any agent
/// wants, now living in the SDK instead of being re-implemented per app. Each is a self-contained
/// `OrchestratorTool` with pure logic exposed as static functions (so the transforms are
/// unit-testable without the agent loop). This is where Mnemosyne's per-app utility tools migrate.

/// Case / slug transforms.
public enum TextTransform {
    public static func transform(_ text: String, mode: String) -> String {
        switch mode.lowercased() {
        case "upper": return text.uppercased()
        case "lower": return text.lowercased()
        case "title": return text.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
        case "snake": return slug(text, sep: "_")
        case "kebab": return slug(text, sep: "-")
        case "reverse": return String(text.reversed())
        default: return text
        }
    }

    /// URL/filename-safe slug: lowercased, non-alphanumerics collapsed to `sep`, trimmed.
    public static func slug(_ text: String, sep: String = "-") -> String {
        let lowered = text.lowercased()
        var out = ""
        var lastWasSep = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                out.append(ch); lastWasSep = false
            } else if !lastWasSep {
                out.append(sep); lastWasSep = true
            }
        }
        while out.hasPrefix(sep) { out.removeFirst(sep.count) }
        while out.hasSuffix(sep) { out.removeLast(sep.count) }
        return out
    }
}

public struct TextTransformTool: OrchestratorTool {
    public init() {}
    public let name = "text_transform"
    public let toolDescription = "Transform text: mode = upper | lower | title | snake | kebab | reverse."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "text": ["type": "string", "description": "The text to transform."],
        "mode": ["type": "string", "description": "upper, lower, title, snake, kebab, or reverse."],
    ], "required": ["text", "mode"]] }
    public func invoke(arguments: String) async -> String {
        let a = JSONArgs(arguments)
        guard let text = a.string("text"), let mode = a.string("mode") else { return "Error: missing 'text'/'mode'." }
        return TextTransform.transform(text, mode: mode)
    }
}

/// Base64 encode/decode.
public enum Base64 {
    public static func encode(_ text: String) -> String { Data(text.utf8).base64EncodedString() }
    /// Decode base64 to text. Tolerant of embedded whitespace/newlines; nil when the input isn't
    /// valid base64 or the bytes aren't valid UTF-8.
    public static func decode(_ b64: String) -> String? {
        guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

public struct Base64Tool: OrchestratorTool {
    public init() {}
    public let name = "base64"
    public let toolDescription = "Base64 encode or decode text. mode = encode | decode."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "text": ["type": "string", "description": "Text to encode, or base64 to decode."],
        "mode": ["type": "string", "description": "encode (default) or decode."],
    ], "required": ["text"]] }
    public func invoke(arguments: String) async -> String {
        let a = JSONArgs(arguments)
        guard let text = a.string("text") else { return "Error: missing 'text'." }
        if (a.string("mode") ?? "encode").lowercased() == "decode" {
            return Base64.decode(text) ?? "Error: not valid base64 / UTF-8."
        }
        return Base64.encode(text)
    }
}

/// Count characters, words, and lines.
public struct WordCountTool: OrchestratorTool {
    public init() {}
    public let name = "word_count"
    public let toolDescription = "Count characters, words, and lines in some text."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "text": ["type": "string", "description": "The text to measure."],
    ], "required": ["text"]] }
    public func invoke(arguments: String) async -> String {
        let a = JSONArgs(arguments)
        guard let text = a.string("text") else { return "Error: missing 'text'." }
        let words = text.split { $0.isWhitespace }.count
        let lines = text.isEmpty ? 0 : text.components(separatedBy: "\n").count
        return "\(text.count) characters, \(words) words, \(lines) lines."
    }
}

/// Pretty-print or minify JSON.
public struct JSONFormatTool: OrchestratorTool {
    public init() {}
    public let name = "json_format"
    public let toolDescription = "Pretty-print or minify a JSON string. mode = pretty | minify."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "json": ["type": "string", "description": "The JSON to format."],
        "mode": ["type": "string", "description": "pretty (default) or minify."],
    ], "required": ["json"]] }
    public func invoke(arguments: String) async -> String {
        let a = JSONArgs(arguments)
        guard let json = a.string("json") else { return "Error: missing 'json'." }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) else {
            return "Error: not valid JSON."
        }
        let opts: JSONSerialization.WritingOptions = (a.string("mode") ?? "pretty").lowercased() == "minify"
            ? [.sortedKeys, .fragmentsAllowed]
            : [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: opts),
              let s = String(data: data, encoding: .utf8) else { return "Error: couldn't format." }
        return s
    }
}

public enum TextTools {
    /// The generic text/encoding utility tools, ready to add to `Orchestrator.run`.
    public static func all() -> [OrchestratorTool] {
        [TextTransformTool(), Base64Tool(), WordCountTool(), JSONFormatTool()]
    }
}
