import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Generic hashing / HTML-entity tools for the SDK. SHA-256 uses CryptoKit where available
/// (Apple platforms) and a small pure-Swift fallback elsewhere, so the tool works cross-platform.
/// Self-contained pure helpers + thin `OrchestratorTool` wrappers. Pure → unit-testable.

public enum Hashing {
    /// Lowercase hex SHA-256 of the UTF-8 bytes of `text`.
    public static func sha256Hex(_ text: String) -> String {
        let bytes = Array(text.utf8)
        #if canImport(CryptoKit)
        return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
        #else
        return SHA256Pure.hash(bytes).map { String(format: "%02x", $0) }.joined()
        #endif
    }

    /// First 12 hex chars — a short fingerprint for dedup / display.
    public static func short(_ text: String) -> String { String(sha256Hex(text).prefix(12)) }
}

public enum HTMLEntities {
    /// Escape the 5 core HTML entities. `&` first so it doesn't double-escape.
    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Reverse of `escape` (the 5 core entities). `&amp;` last so it doesn't undo too early.
    public static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

public struct HashTool: OrchestratorTool {
    public init() {}
    public let name = "hash_text"
    public let toolDescription = "SHA-256 fingerprint of text (full hex + a short 12-char form) — for checksums, dedup, or identical-content checks."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "text": ["type": "string", "description": "The text to hash."],
    ], "required": ["text"]] }
    public func invoke(arguments: String) async -> String {
        guard let text = JSONArgs(arguments).string("text"), !text.isEmpty else { return "Error: missing 'text'." }
        return "SHA-256: \(Hashing.sha256Hex(text))\nShort: \(Hashing.short(text))"
    }
}

public struct HTMLEntitiesTool: OrchestratorTool {
    public init() {}
    public let name = "html_entities"
    public let toolDescription = "Escape or unescape HTML entities (& < > \" '). Set 'mode' to 'escape' (default) or 'unescape'."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "text": ["type": "string", "description": "The text to escape/unescape."],
        "mode": ["type": "string", "description": "'escape' (default) or 'unescape'."],
    ], "required": ["text"]] }
    public func invoke(arguments: String) async -> String {
        let a = JSONArgs(arguments)
        guard let text = a.string("text") else { return "Error: missing 'text'." }
        return (a.string("mode") ?? "escape").lowercased() == "unescape" ? HTMLEntities.unescape(text) : HTMLEntities.escape(text)
    }
}

public enum HashTools {
    /// The generic hashing / HTML-entity tools, ready to add to `Orchestrator.run`.
    public static func all() -> [OrchestratorTool] { [HashTool(), HTMLEntitiesTool()] }
}

#if !canImport(CryptoKit)
/// Minimal pure-Swift SHA-256 fallback for platforms without CryptoKit.
enum SHA256Pure {
    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]
        var msg = message
        let bitLen = UInt64(message.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0..<8).reversed() { msg.append(UInt8((bitLen >> (UInt64(i) * 8)) & 0xff)) }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        for chunk in stride(from: 0, to: msg.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = (UInt32(msg[j]) << 24) | (UInt32(msg[j + 1]) << 16) | (UInt32(msg[j + 2]) << 8) | UInt32(msg[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ S1 &+ ch &+ k[i] &+ w[i]
                let S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = S0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.flatMap { [UInt8($0 >> 24 & 0xff), UInt8($0 >> 16 & 0xff), UInt8($0 >> 8 & 0xff), UInt8($0 & 0xff)] }
    }
}
#endif
