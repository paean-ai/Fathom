import Foundation

/// The final answer couldn't be decoded as the requested type, even after guardrail retries.
public struct StructuredOutputError: Error, Sendable, CustomStringConvertible {
    /// The raw final answer the model produced.
    public let answer: String
    /// The decoding failure, rendered.
    public let underlying: String
    public var description: String { "Structured output didn't decode: \(underlying)" }
}

public extension Orchestrator {
    /// Run the loop and return the final answer DECODED as `T` — the primitive that turns an
    /// agent into a composable pipeline stage (callers get a typed value, not prose to parse).
    /// The model is instructed to answer ONLY with JSON matching `schemaHint` (any shape
    /// description works: a JSON Schema, a Swift-like sketch, or an example object); the
    /// existing output-guardrail machinery regenerates — bounded by `maxGuardrailRetries`,
    /// raised to at least 2 here — feeding the decode error back each time. Throws
    /// `StructuredOutputError` if the answer still doesn't decode after the retries.
    func runStructured<T: Decodable>(_ type: T.Type = T.self,
                                     systemPrompt: String, query: String,
                                     history: [ChatMessage] = [],
                                     tools: [OrchestratorTool] = [],
                                     schemaHint: String) async throws -> (value: T, run: RunResult) {
        var structured = self
        structured.outputGuardrail = { answer in
            switch Self.decodeStructured(T.self, from: answer) {
            case .success: return .pass
            case .failure(let e): return .retry("your answer must be ONLY a JSON value matching the required schema — no prose, no code fences. Decoding failed: \(e.underlying)")
            }
        }
        structured.maxGuardrailRetries = max(maxGuardrailRetries, 2)
        let sys = systemPrompt
            + "\n\nOUTPUT FORMAT — your final answer must be ONLY a JSON value matching this schema, with no prose around it:\n"
            + schemaHint
        let run = try await structured.run(systemPrompt: sys, query: query, history: history, tools: tools)
        switch Self.decodeStructured(T.self, from: run.answer) {
        case .success(let value): return (value, run)
        case .failure(let error): throw error
        }
    }

    /// Extract the JSON payload from a model answer: strips markdown code fences and any prose
    /// around the outermost `{…}` / `[…]`. Returns the trimmed text unchanged when no JSON
    /// delimiters are present (so scalar answers like `42` still parse). Pure → testable.
    static func extractJSON(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = t.firstIndex(where: { $0 == "{" || $0 == "[" }),
           let end = t.lastIndex(where: { $0 == "}" || $0 == "]" }), start < end {
            return String(t[start...end])
        }
        return t
    }

    /// Decode a model answer as `T` via `extractJSON`. Pure.
    static func decodeStructured<T: Decodable>(_ type: T.Type, from answer: String)
        -> Result<T, StructuredOutputError> {
        let json = extractJSON(answer)
        do { return .success(try JSONDecoder().decode(T.self, from: Data(json.utf8))) }
        catch { return .failure(StructuredOutputError(answer: answer, underlying: String(describing: error))) }
    }
}

public extension Agent {
    /// Run a query and return the answer decoded as `T` (see `Orchestrator.runStructured`).
    func runStructured<T: Decodable>(_ type: T.Type = T.self, query: String,
                                     history: [ChatMessage] = [],
                                     schemaHint: String) async throws -> (value: T, run: RunResult) {
        try await orchestrator.runStructured(type, systemPrompt: systemPrompt, query: query,
                                             history: history, tools: tools, schemaHint: schemaHint)
    }
}
