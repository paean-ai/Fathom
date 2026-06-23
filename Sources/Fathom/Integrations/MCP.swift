import Foundation

/// Model Context Protocol (MCP) support — lets a Fathom agent use tools served by any MCP server
/// (filesystem, git, a database, …), the same way Claude Code / Codex do. This file is the pure,
/// transport-agnostic core: JSON-RPC 2.0 framing for the three calls an agent needs
/// (`initialize`, `tools/list`, `tools/call`) and a bridge that turns an MCP tool definition into
/// a Fathom `OrchestratorTool`. The actual transport (a stdio subprocess or HTTP) is injected via
/// `MCPTransport`, so this layer is fully unit-testable with a mock.
public enum MCP {
    /// JSON-RPC protocol version MCP rides on.
    public static let jsonRPCVersion = "2.0"
    /// MCP revision this client speaks.
    public static let protocolVersion = "2024-11-05"

    // MARK: Requests (encode)

    /// Build a JSON-RPC request envelope for `method` with `params`, tagged with `id`.
    public static func request(id: Int, method: String, params: [String: Any] = [:]) -> [String: Any] {
        var env: [String: Any] = ["jsonrpc": jsonRPCVersion, "id": id, "method": method]
        if !params.isEmpty { env["params"] = params }
        return env
    }

    /// The `initialize` handshake a client sends first, advertising its protocol version + name.
    public static func initializeRequest(id: Int, clientName: String = "Fathom",
                                         clientVersion: String = "1.0") -> [String: Any] {
        request(id: id, method: "initialize", params: [
            "protocolVersion": protocolVersion,
            "capabilities": [:],
            "clientInfo": ["name": clientName, "version": clientVersion],
        ])
    }

    /// `tools/list` — ask the server what tools it offers.
    public static func listToolsRequest(id: Int) -> [String: Any] {
        request(id: id, method: "tools/list")
    }

    /// `tools/call` — invoke `name` with `arguments` (already-decoded JSON object).
    public static func callToolRequest(id: Int, name: String, arguments: [String: Any]) -> [String: Any] {
        request(id: id, method: "tools/call", params: ["name": name, "arguments": arguments])
    }

    // MARK: Responses (decode)

    /// A tool advertised by an MCP server.
    public struct ToolDef: Sendable, Equatable {
        public let name: String
        public let description: String
        /// JSON-Schema object describing the tool's arguments (already a `[String: Any]`).
        public let inputSchema: Data   // stored as JSON Data to stay Sendable/Equatable
        public init(name: String, description: String, inputSchema: [String: Any]) {
            self.name = name; self.description = description
            self.inputSchema = (try? JSONSerialization.data(withJSONObject: inputSchema)) ?? Data("{}".utf8)
        }
        /// The decoded JSON-Schema parameters object (`{}` if it can't be read).
        public var parameters: [String: Any] {
            (try? JSONSerialization.jsonObject(with: inputSchema)) as? [String: Any] ?? [:]
        }
    }

    /// Parse a `tools/list` response body into tool definitions. Returns [] when the shape is off.
    public static func parseToolsList(_ data: Data) -> [ToolDef] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = obj["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else { return [] }
        return tools.compactMap { t in
            guard let name = t["name"] as? String else { return nil }
            let desc = t["description"] as? String ?? ""
            let schema = t["inputSchema"] as? [String: Any] ?? ["type": "object"]
            return ToolDef(name: name, description: desc, inputSchema: schema)
        }
    }

    /// Extract the textual result from a `tools/call` response. MCP returns `result.content` as an
    /// array of typed blocks; we concatenate the `text` blocks (the common case). On a JSON-RPC
    /// `error`, returns "Error: <message>". nil only if the body is unparseable.
    public static func parseToolResult(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = obj["error"] as? [String: Any] {
            let msg = error["message"] as? String ?? "unknown error"
            return "Error: \(msg)"
        }
        guard let result = obj["result"] as? [String: Any] else { return nil }
        if let content = result["content"] as? [[String: Any]] {
            let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return text.isEmpty ? "(no text content)" : text
        }
        // Some servers return a bare structured result; serialize it as a fallback.
        if let d = try? JSONSerialization.data(withJSONObject: result),
           let s = String(data: d, encoding: .utf8) { return s }
        return nil
    }

    // MARK: stdio wire framing (newline-delimited JSON-RPC)

    /// Serialize a JSON-RPC message to bytes (no framing) — the `Sendable` form a transport ships.
    public static func encode(_ message: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: message)) ?? Data("{}".utf8)
    }

    /// Encode a JSON-RPC message as a single newline-terminated line — the MCP stdio wire format
    /// ("messages are delimited by newlines and MUST NOT contain embedded newlines").
    public static func encodeMessage(_ message: [String: Any]) -> Data {
        var d = encode(message)
        d.append(0x0A)   // '\n'
        return d
    }

    /// The `id` of a JSON-RPC message line, or nil for notifications / unparseable lines.
    public static func messageID(_ line: Data) -> Int? {
        ((try? JSONSerialization.jsonObject(with: line)) as? [String: Any])?["id"] as? Int
    }

    /// Accumulates bytes from a stdio stream and yields complete newline-delimited messages.
    /// A partial trailing line is held until the rest arrives, so a message split across reads is
    /// reassembled correctly.
    public struct MessageFramer: Sendable {
        private var buffer = Data()
        public init() {}
        /// Append new bytes; return any now-complete messages (trailing newline stripped, blanks skipped).
        public mutating func push(_ data: Data) -> [Data] {
            buffer.append(data)
            var out: [Data] = []
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                if !line.isEmpty { out.append(Data(line)) }
                buffer.removeSubrange(buffer.startIndex...nl)
            }
            return out
        }
    }
}

/// Errors raised by the host-side MCP transports.
public enum MCPError: Error, Sendable {
    /// The server closed its stdout (EOF) before answering.
    case connectionClosed
    /// The transport could not launch the server process.
    case launchFailed(String)
}

/// Drives the MCP handshake over any `MCPTransport` and bridges the server's tools into Fathom
/// `OrchestratorTool`s. One `connect()` runs `initialize` then `tools/list`, returning ready-to-run
/// tools — drop them straight into `Orchestrator.run`'s tool list, exactly like Claude Code attaches
/// an MCP server's tools to its session.
public struct MCPClient: Sendable {
    private let transport: any MCPTransport
    private let clientName: String
    private let clientVersion: String

    public init(transport: any MCPTransport, clientName: String = "Fathom", clientVersion: String = "1.0") {
        self.transport = transport
        self.clientName = clientName
        self.clientVersion = clientVersion
    }

    /// Handshake + list tools. `isMutating` is applied to every bridged tool (MCP servers may have
    /// side effects, so the default is `true`; pass `false` for a known read-only server to let the
    /// orchestrator's guardrails treat them as safe).
    public func connect(isMutating: Bool = true) async throws -> [OrchestratorTool] {
        _ = try await transport.send(MCP.encode(MCP.initializeRequest(id: 1, clientName: clientName, clientVersion: clientVersion)))
        let listData = try await transport.send(MCP.encode(MCP.listToolsRequest(id: 2)))
        let defs = MCP.parseToolsList(listData)
        return defs.enumerated().map { index, def in
            MCPTool(def: def, transport: transport, isMutating: isMutating, callID: 1000 + index)
        }
    }
}

/// Transport that ships a JSON-RPC request (serialized via `MCP.encode`) to an MCP server and
/// returns its raw response message bytes. Implemented host-side (stdio subprocess / HTTP) and
/// injected so the protocol layer stays testable. Ships `Data` (Sendable) rather than a dictionary
/// so an `actor` transport can satisfy it under Swift 6 strict concurrency.
public protocol MCPTransport: Sendable {
    func send(_ request: Data) async throws -> Data
}

/// Adapts one MCP `ToolDef` into a Fathom `OrchestratorTool`, so MCP-served tools drop straight
/// into the orchestrator's tool list alongside native tools. `invoke` JSON-RPCs the server through
/// the transport. MCP tools are treated as mutating (servers may have side effects) unless told
/// otherwise.
public struct MCPTool: OrchestratorTool {
    public let name: String
    public let toolDescription: String
    public let isMutating: Bool
    /// Stored as JSON `Data` (Sendable); decoded on demand so the struct is `Sendable` under Swift 6.
    private let inputSchemaData: Data
    private let transport: any MCPTransport
    private let callID: Int

    public var parameters: [String: Any] {
        (try? JSONSerialization.jsonObject(with: inputSchemaData)) as? [String: Any] ?? [:]
    }

    public init(def: MCP.ToolDef, transport: any MCPTransport, isMutating: Bool = true, callID: Int = 1) {
        self.name = def.name
        self.toolDescription = def.description
        self.inputSchemaData = def.inputSchema
        self.transport = transport
        self.isMutating = isMutating
        self.callID = callID
    }

    public func invoke(arguments: String) async -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        let req = MCP.callToolRequest(id: callID, name: name, arguments: args)
        do {
            let data = try await transport.send(MCP.encode(req))
            return MCP.parseToolResult(data) ?? "(empty MCP response)"
        } catch {
            return "MCP call failed: \(error.localizedDescription)"
        }
    }
}
