# Fathom

*Fathom the depths, surface the answer.*

A small, dependency-free Swift **agent SDK** for DeepSeek-style (OpenAI-compatible) models.
Define an `Agent` — a model + system prompt + tools + policies — and it drives a full
tool-calling loop to an answer. Not just an API wrapper: it ships the machinery a real
agent needs.

**What you get**

- **`Agent` + `Thread`** — a reusable agent, and stateful multi-turn conversations with memory.
- **Plan → Act → Verify** — optional planning (decompose the goal into steps first) and a
  critic (review the draft answer and revise once if it falls short) — a *thinking* agent.
- **Tool-calling loop** with production safety rails:
  - *No repeated tool calls* — identical calls (even with reordered JSON keys) are collapsed.
  - *No-progress cap* — two rounds that add nothing new force a final answer.
  - *Round cap* — a hard ceiling on tool-calling rounds.
- **Human-in-the-loop approval** — mutating tools are gated through an `approval` hook; deny
  with a reason and the model adapts. Read-only tools never prompt.
- **Parallel tool execution** — independent tool calls in one round run concurrently.
- **Observation hook** — collect side effects (citations, traces) as the loop runs.
- **Resilience** — wrap any client in `RetryingClient` for retry + backoff on transient failures.
- **Built-in general tools** — `CalculatorTool`, `UnitConvertTool`, `CurrentDateTimeTool`, and `TranslateTool`,
  ready to drop into any agent; bring your own for app-specific capabilities.

Fully mockable (inject any `LLMClient`) — the whole thing is testable offline, no network.

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

let agent = Agent(
    client: client,
    systemPrompt: "You are a helpful research assistant.",
    tools: [search]
)

let result = try await agent.run("What changed in the Q3 report?")
print(result.answer)         // the model's final answer
print(result.toolCallCount)  // how many tools ran
print(result.finish)         // .natural / .noProgress / .roundLimit
```

### Multi-turn conversations

```swift
let thread = agent.thread()
_ = try await thread.send("Summarize the report.")
_ = try await thread.send("Now compare it to last year.")   // remembers the first turn
print(thread.messages)   // the running transcript
```

### Human-in-the-loop approval

Mutating tools (`isMutating: true`) are gated through `approval`; read-only tools never prompt.

```swift
let agent = Agent(
    client: client, systemPrompt: "…", tools: [deleteTool],
    approval: { call in
        await userConfirms(call) ? .allow : .deny("user declined")
    }
)
```

### Plan → Act → Verify

Turn on planning (decompose first) and the critic (review + revise) for a thinking agent:

```swift
let agent = Agent(client: client, systemPrompt: "…", tools: tools,
                  planning: true, critic: true)
let result = try await agent.run("Compare last two quarterly reports and flag risks.")
print(result.plan)      // the steps it decomposed the goal into
print(result.revised)   // true if the critic forced a revision
```

### Resilience

```swift
let client = RetryingClient(wrapping: DeepSeekClient(config: cfg), maxAttempts: 4)
```

### Collecting side effects as the loop runs

`onObservation` fires after every tool call (fresh or de-duplicated repeat) — the seam a
host uses to gather citations or traces without owning the loop:

```swift
let agent = Agent(
    client: client, systemPrompt: "…", tools: tools,
    onObservation: { obs in
        print(obs.toolName, obs.arguments, obs.isRepeat, obs.approved)
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
