import Foundation

/// One open-web search result. App-agnostic so any engine can produce it.
public struct WebResult: Sendable, Equatable {
    public let title: String
    public let url: String
    public let snippet: String
    public init(title: String, url: String, snippet: String) {
        self.title = title; self.url = url; self.snippet = snippet
    }
}

/// A web-search backend the host supplies — Fathom stays dependency-free and never makes
/// network calls itself. Conform your own client (SerpAPI, DuckDuckGo, Brave, …) and hand
/// it to `WebSearchTool` / `WebFetchTool`.
public protocol WebSearchEngine: Sendable {
    /// Search the open web; return [] on failure (don't throw — degrade gracefully).
    func search(_ query: String, limit: Int) async -> [WebResult]
    /// Fetch a page and return its readable text, or nil on failure.
    func fetch(_ url: String) async -> String?
}

/// Built-in tool: search the open web via the host's `WebSearchEngine`.
public struct WebSearchTool: OrchestratorTool {
    private let engine: WebSearchEngine
    private let limit: Int
    public init(engine: WebSearchEngine, limit: Int = 6) { self.engine = engine; self.limit = limit }
    public var name: String { "web_search" }
    public var toolDescription: String {
        "Search the OPEN WEB for current information. Returns titled results with URLs and snippets to cite."
    }
    public var parameters: [String: Any] {
        ["type": "object",
         "properties": ["query": ["type": "string", "description": "a focused web search query"]],
         "required": ["query"]]
    }
    public func invoke(arguments: String) async -> String {
        guard let q = jsonString(arguments, "query")?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty else {
            return "Missing 'query'."
        }
        let results = await engine.search(q, limit: limit)
        guard !results.isEmpty else { return "No web results for '\(q)'." }
        return results.enumerated().map { i, r in
            "[\(i + 1)] \(r.title)\n\(r.url)\n\(r.snippet)"
        }.joined(separator: "\n\n")
    }
}

/// Built-in tool: fetch and read a web page via the host's `WebSearchEngine`.
public struct WebFetchTool: OrchestratorTool {
    private let engine: WebSearchEngine
    public init(engine: WebSearchEngine) { self.engine = engine }
    public var name: String { "fetch_url" }
    public var toolDescription: String {
        "Fetch a web page and return its readable text — read a result rather than just its snippet."
    }
    public var parameters: [String: Any] {
        ["type": "object",
         "properties": ["url": ["type": "string", "description": "the page URL to read"]],
         "required": ["url"]]
    }
    public func invoke(arguments: String) async -> String {
        guard let url = jsonString(arguments, "url")?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else {
            return "Missing 'url'."
        }
        guard let text = await engine.fetch(url), !text.isEmpty else {
            return "Couldn't read \(url) (unreachable or empty)."
        }
        return text
    }
}
