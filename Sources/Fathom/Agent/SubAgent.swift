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
