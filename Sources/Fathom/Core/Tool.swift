import Foundation

/// A tool the orchestrator can call. Implement this to expose any capability — the
/// orchestrator handles the loop, de-duplication, and result threading.
public protocol OrchestratorTool: Sendable {
    /// Unique function name the model calls.
    var name: String { get }
    /// What it does (shown to the model).
    var toolDescription: String { get }
    /// JSON-Schema `parameters` object (OpenAI function-calling style).
    var parameters: [String: Any] { get }
    /// Whether the tool mutates state (used to skip the question-oriented verify pass).
    var isMutating: Bool { get }
    /// Run the tool with the model's raw JSON arguments; return a textual result.
    func invoke(arguments: String) async -> String
}

public extension OrchestratorTool {
    var isMutating: Bool { false }

    /// The OpenAI-style tool schema dictionary the API expects.
    var schema: [String: Any] {
        ["type": "function",
         "function": ["name": name, "description": toolDescription, "parameters": parameters]]
    }
}

/// A closure-based tool, for quick definitions without a dedicated type. The schema
/// is stored as JSON `Data` so the struct stays `Sendable` under Swift 6.
public struct ClosureTool: OrchestratorTool {
    public let name: String
    public let toolDescription: String
    public let isMutating: Bool
    private let parametersData: Data
    private let run: @Sendable (String) async -> String

    public var parameters: [String: Any] {
        (try? JSONSerialization.jsonObject(with: parametersData)) as? [String: Any] ?? [:]
    }

    public init(name: String, description: String, parameters: [String: Any] = [:],
                isMutating: Bool = false, run: @escaping @Sendable (String) async -> String) {
        self.name = name; self.toolDescription = description; self.isMutating = isMutating; self.run = run
        self.parametersData = (try? JSONSerialization.data(withJSONObject: parameters.isEmpty ? ["type": "object", "properties": [:]] : parameters))
            ?? Data("{}".utf8)
    }
    public func invoke(arguments: String) async -> String { await run(arguments) }
}
