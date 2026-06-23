import Foundation

/// Wrap an `Agent` as a TOOL so a parent agent can DELEGATE a focused sub-task to a
/// specialized sub-agent — its own system prompt, tools, and policies (planning, critic,
/// approval). The building block for hierarchical / multi-agent workflows: a generalist
/// orchestrates while specialists do the deep work.
///
/// ```swift
/// let researcher = Agent(client: client, systemPrompt: "You research thoroughly.", tools: [webSearch])
/// let delegate = SubAgentTool(name: "research", description: "Delegate deep research", agent: researcher)
/// let lead = Agent(client: client, systemPrompt: "You coordinate.", tools: [delegate])
/// ```
public struct SubAgentTool: OrchestratorTool {
    private let agent: Agent
    public let name: String
    public let toolDescription: String

    public init(name: String, description: String, agent: Agent) {
        self.name = name; self.toolDescription = description; self.agent = agent
    }

    public var parameters: [String: Any] {
        ["type": "object",
         "properties": ["task": ["type": "string", "description": "the self-contained sub-task to delegate"]],
         "required": ["task"]]
    }

    public func invoke(arguments: String) async -> String {
        guard let task = jsonString(arguments, "task")?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty else {
            return "Missing 'task'."
        }
        guard let result = try? await agent.run(task) else { return "The sub-agent couldn't complete the task." }
        return result.answer.isEmpty ? "The sub-agent returned no answer." : result.answer
    }
}

/// A named specialist sub-agent a parent can delegate to by `type`.
public struct Specialist: Sendable {
    public let type: String
    public let description: String
    public let agent: Agent
    public init(type: String, description: String, agent: Agent) {
        self.type = type; self.description = description; self.agent = agent
    }
}

/// One tool that DYNAMICALLY routes a delegated task to whichever of several named specialists the
/// model picks — the agentic-fan-out primitive, like Claude Code's Task tool choosing a
/// `subagent_type`. Where `SubAgentTool` wraps a single fixed agent, this exposes a *menu*: its
/// description enumerates the specialists, its `type` parameter is constrained to their names, and
/// `invoke` runs the chosen one to completion. An unknown `type` returns the valid list rather than
/// failing silently.
///
/// ```swift
/// let router = SubAgentRouterTool(specialists: [
///     Specialist(type: "researcher", description: "Deep web research", agent: researcher),
///     Specialist(type: "coder",      description: "Write & edit code",  agent: coder),
/// ])
/// let lead = Agent(client: client, systemPrompt: "You coordinate specialists.", tools: [router])
/// ```
public struct SubAgentRouterTool: OrchestratorTool {
    private let specialists: [String: Specialist]
    private let order: [String]
    public let name: String
    public let toolDescription: String
    /// A specialist may use mutating tools, so a delegation is treated as mutating.
    public let isMutating = true

    public init(name: String = "spawn_subagent", specialists: [Specialist]) {
        self.name = name
        self.order = specialists.map(\.type)
        self.specialists = Dictionary(specialists.map { ($0.type, $0) }, uniquingKeysWith: { _, last in last })
        let menu = specialists.map { "- \($0.type): \($0.description)" }.joined(separator: "\n")
        self.toolDescription = "Delegate a self-contained sub-task to a specialist sub-agent."
            + (menu.isEmpty ? "" : " Available types:\n\(menu)")
    }

    public var parameters: [String: Any] {
        ["type": "object",
         "properties": [
            "type": ["type": "string", "description": "which specialist to use", "enum": order],
            "task": ["type": "string", "description": "the self-contained sub-task to delegate"],
         ],
         "required": ["type", "task"]]
    }

    public func invoke(arguments: String) async -> String {
        guard let task = jsonString(arguments, "task")?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty else {
            return "Missing 'task'."
        }
        let requested = jsonString(arguments, "type")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let specialist = specialists[requested] else {
            let valid = order.isEmpty ? "(none configured)" : order.joined(separator: ", ")
            return "Unknown specialist type '\(requested)'. Available: \(valid)."
        }
        guard let result = try? await specialist.agent.run(task) else {
            return "The '\(requested)' sub-agent couldn't complete the task."
        }
        return result.answer.isEmpty ? "The '\(requested)' sub-agent returned no answer." : result.answer
    }
}
