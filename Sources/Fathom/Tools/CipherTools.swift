import Foundation

/// Generic cipher / encoding tools for the SDK — Caesar & Vigenère ciphers, Morse code, and URL
/// percent-encoding. Self-contained (pure static logic + a thin `OrchestratorTool` wrapper each),
/// Foundation-only (no platform crypto), so any Fathom agent gets them. Pure helpers →
/// unit-testable. (base64 lives in `TextTools`.)

/// Caesar / ROT-N cipher. Case and non-letters preserved; ROT13 (shift 13) decodes itself.
public enum Caesar {
    public static func shift(_ text: String, by n: Int) -> String {
        let k = UInt8(((n % 26) + 26) % 26)
        return String(text.map { ch -> Character in
            guard ch.isLetter, ch.isASCII, let a = ch.asciiValue else { return ch }
            let base: UInt8 = ch.isUppercase ? 65 : 97
            return Character(UnicodeScalar(base + (a - base + k) % 26))
        })
    }
}

/// Vigenère polyalphabetic cipher — each letter shifted by the next letter of a repeating keyword.
public enum Vigenere {
    /// nil when the key has no letters. `decode` inverts the shift. Non-letters pass through and
    /// don't consume a key letter.
    public static func transform(_ text: String, key: String, decode: Bool) -> String? {
        let shifts = key.lowercased().filter { $0.isLetter && $0.isASCII }
            .map { Int($0.asciiValue! - 97) }
        guard !shifts.isEmpty else { return nil }
        var ki = 0, out = ""
        for ch in text {
            guard ch.isLetter, ch.isASCII, let a = ch.asciiValue else { out.append(ch); continue }
            let base: UInt8 = ch.isUppercase ? 65 : 97
            let off = Int(a - base), s = shifts[ki % shifts.count]
            let shifted = decode ? (off - s + 26) % 26 : (off + s) % 26
            out.append(Character(UnicodeScalar(base + UInt8(shifted))))
            ki += 1
        }
        return out
    }
}

/// International Morse code (letters, digits, common punctuation).
public enum Morse {
    static let table: [Character: String] = [
        "a": ".-", "b": "-...", "c": "-.-.", "d": "-..", "e": ".", "f": "..-.", "g": "--.",
        "h": "....", "i": "..", "j": ".---", "k": "-.-", "l": ".-..", "m": "--", "n": "-.",
        "o": "---", "p": ".--.", "q": "--.-", "r": ".-.", "s": "...", "t": "-", "u": "..-",
        "v": "...-", "w": ".--", "x": "-..-", "y": "-.--", "z": "--..",
        "0": "-----", "1": ".----", "2": "..---", "3": "...--", "4": "....-",
        "5": ".....", "6": "-....", "7": "--...", "8": "---..", "9": "----.",
        ".": ".-.-.-", ",": "--..--", "?": "..--..", "!": "-.-.--", "/": "-..-.", "-": "-....-",
    ]
    static let reverse: [String: Character] = { var m = [String: Character](); for (k, v) in table { m[v] = k }; return m }()

    public static func encode(_ text: String) -> String? {
        let words = text.lowercased().split(separator: " ", omittingEmptySubsequences: true)
        let enc = words.compactMap { w -> String? in
            let codes = w.compactMap { table[$0] }
            return codes.isEmpty ? nil : codes.joined(separator: " ")
        }
        return enc.isEmpty ? nil : enc.joined(separator: " / ")
    }

    public static func decode(_ morse: String) -> String? {
        let trimmed = morse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let words = trimmed.components(separatedBy: "/").map { word -> String in
            word.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
                .map { reverse[String($0)].map(String.init) ?? "?" }.joined()
        }.filter { !$0.isEmpty }
        return words.isEmpty ? nil : words.joined(separator: " ").uppercased()
    }
}

// MARK: - Tools

public struct CaesarTool: OrchestratorTool {
    public init() {}
    public let name = "caesar"
    public let toolDescription = "Caesar/ROT-N cipher: shift each letter by 'shift' positions (default 13 = ROT13, which decodes itself)."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "text": ["type": "string", "description": "The text to shift."],
        "shift": ["type": "string", "description": "Letters to shift (default 13). Negative to decode a forward shift."],
    ], "required": ["text"]] }
    public func invoke(arguments: String) async -> String {
        let a = JSONArgs(arguments)
        guard let text = a.string("text") else { return "Error: missing 'text'." }
        return Caesar.shift(text, by: Int(a.string("shift") ?? "") ?? 13)
    }
}

public struct VigenereTool: OrchestratorTool {
    public init() {}
    public let name = "vigenere"
    public let toolDescription = "Vigenère cipher — encode or decode text with a keyword. Set 'mode' to 'encode' (default) or 'decode'."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "text": ["type": "string", "description": "The text to encode or decode."],
        "key": ["type": "string", "description": "The keyword (letters only are used)."],
        "mode": ["type": "string", "description": "'encode' (default) or 'decode'."],
    ], "required": ["text", "key"]] }
    public func invoke(arguments: String) async -> String {
        let a = JSONArgs(arguments)
        guard let text = a.string("text"), let key = a.string("key") else { return "Error: missing 'text'/'key'." }
        let decode = (a.string("mode") ?? "encode").lowercased() == "decode"
        return Vigenere.transform(text, key: key, decode: decode) ?? "Error: the key must contain at least one letter."
    }
}

public struct MorseTool: OrchestratorTool {
    public init() {}
    public let name = "morse"
    public let toolDescription = "Encode text to International Morse or decode Morse back to text (auto-detects; set 'mode' to force)."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "text": ["type": "string", "description": "Plain text to encode, or dot/dash Morse to decode."],
        "mode": ["type": "string", "description": "'encode', 'decode', or omit to auto-detect."],
    ], "required": ["text"]] }
    public func invoke(arguments: String) async -> String {
        let a = JSONArgs(arguments)
        guard let text = a.string("text") else { return "Error: missing 'text'." }
        let mode = (a.string("mode") ?? "").lowercased()
        let looksLikeMorse = text.allSatisfy { ".-/ \n\t".contains($0) }
        if mode == "decode" || (mode != "encode" && looksLikeMorse) {
            return Morse.decode(text) ?? "Couldn't decode any Morse."
        }
        return Morse.encode(text) ?? "Nothing encodable to Morse."
    }
}

public struct URLEncodeTool: OrchestratorTool {
    public init() {}
    public let name = "url_encode"
    public let toolDescription = "Percent-encode or -decode text for use in a URL. Set 'mode' to 'encode' (default) or 'decode'."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "text": ["type": "string", "description": "Text to encode, or percent-encoded text to decode."],
        "mode": ["type": "string", "description": "'encode' (default) or 'decode'."],
    ], "required": ["text"]] }
    public func invoke(arguments: String) async -> String {
        let a = JSONArgs(arguments)
        guard let text = a.string("text") else { return "Error: missing 'text'." }
        if (a.string("mode") ?? "encode").lowercased() == "decode" {
            return text.removingPercentEncoding ?? "Error: malformed percent-encoding."
        }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}

public enum CipherTools {
    /// The generic cipher/encoding tools, ready to add to `Orchestrator.run`.
    public static func all() -> [OrchestratorTool] { [CaesarTool(), VigenereTool(), MorseTool(), URLEncodeTool()] }
}
