# Fathom

*Fathom the depths, surface the answer.*

A small, dependency-free Swift package for driving a DeepSeek-style (OpenAI-compatible)
tool-calling agent loop. You supply an `LLMClient` and a set of `OrchestratorTool`s; the
`Orchestrator` runs the ACT loop until the model is ready to answer, with the safety rails
baked in (battle-tested agent-loop safety rails):

- **No repeated tool calls** — identical calls (even with reordered JSON keys) are collapsed.
- **No-progress cap** — two rounds that add nothing new force a final answer.
- **Round cap** — a hard ceiling on tool-calling rounds.

It's fully mockable (inject any `LLMClient`) so the loop is testable offline, with no network.

## Install

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/<you>/Fathom.git", from: "0.1.0")
],
targets: [
    .target(name: "MyApp", dependencies: ["Fathom"])
]
```

## Usage

```swift
import Fathom

let client = DeepSeekClient(config: LLMConfig(apiKey: "sk-…"))

let search = ClosureTool(
    name: "search",
    description: "Search the knowledge base",
    parameters: ["type": "object", "properties": [
        "query": ["type": "string", "description": "what to look for"]
    ]]
) { argumentsJSON in
    // decode argumentsJSON, do the work, return a textual result
    "…results…"
}

let orchestrator = Orchestrator(client: client) { status in
    print(status)   // e.g. "Running search…"
}

let result = try await orchestrator.run(
    systemPrompt: "You are a helpful research assistant.",
    query: "What changed in the Q3 report?",
    tools: [search]
)

print(result.answer)         // the model's final answer
print(result.toolCallCount)  // how many tools ran
print(result.finish)         // .natural / .noProgress / .roundLimit
```

### Collecting side effects as the loop runs

`onObservation` fires after every tool call (fresh or de-duplicated repeat) — the seam a
host uses to gather citations or traces without owning the loop:

```swift
let orchestrator = Orchestrator(
    client: client,
    onObservation: { obs in
        print(obs.toolName, obs.arguments, obs.isRepeat)
    }
)
```

## API

| Type | Purpose |
|------|---------|
| `LLMClient` | Protocol for the chat endpoint — inject `DeepSeekClient` or a mock. |
| `DeepSeekClient` | URLSession transport for DeepSeek's `chat/completions` (public `wire`/`parseCompletion`). |
| `OrchestratorTool` / `ClosureTool` | A capability the model can call. |
| `Orchestrator` | The tool-calling ACT loop with safety rails + observation hook. |
| `ChatMessage` / `ToolCall` / `Completion` / `RunResult` / `FinishReason` | Chat primitives. |

## Testing

```
swift test
```

The loop is exercised with a scripted mock `LLMClient` — no network or API key required.

## License

Apache-2.0. See [LICENSE](LICENSE).
