import Foundation

#if os(macOS) || os(Linux)

/// A real stdio `MCPTransport` — launches an MCP server as a child process and speaks
/// newline-delimited JSON-RPC over its stdin/stdout, the same wire protocol Claude Code and Codex
/// use to talk to `npx`-style MCP servers (filesystem, git, sqlite, …). Construct one, hand it to
/// `MCPClient`, and the server's tools become Fathom `OrchestratorTool`s.
///
/// The process launches lazily on the first `send` and stays alive across calls. An `actor` keeps
/// the pipes and the message framer serialized, so concurrent `send`s can't interleave reads.
public actor StdioMCPTransport: MCPTransport {
    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]?

    private let process = Process()
    private let inPipe = Pipe()
    private let outPipe = Pipe()
    private var framer = MCP.MessageFramer()
    private var started = false

    /// - Parameters:
    ///   - executable: absolute path to the server binary (e.g. `/usr/bin/env` or a launcher).
    ///   - arguments: its arguments (e.g. `["npx", "-y", "@modelcontextprotocol/server-filesystem", "/path"]`).
    ///   - environment: optional environment overrides; nil inherits the parent's.
    public init(executable: String, arguments: [String] = [], environment: [String: String]? = nil) {
        self.executableURL = URL(fileURLWithPath: executable)
        self.arguments = arguments
        self.environment = environment
    }

    private func startIfNeeded() throws {
        guard !started else { return }
        process.executableURL = executableURL
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = inPipe
        process.standardOutput = outPipe
        do {
            try process.run()
        } catch {
            throw MCPError.launchFailed("\(executableURL.path): \(error.localizedDescription)")
        }
        started = true
    }

    public func send(_ request: Data) async throws -> Data {
        try startIfNeeded()
        let wanted = MCP.messageID(request)
        var line = request
        line.append(0x0A)   // newline-delimited wire framing
        inPipe.fileHandleForWriting.write(line)

        // Read until a message with the requested id arrives. Notifications (no id) and responses
        // to other in-flight ids are buffered/skipped; `availableData` returns empty at EOF.
        while true {
            let chunk = outPipe.fileHandleForReading.availableData
            if chunk.isEmpty { throw MCPError.connectionClosed }
            for message in framer.push(chunk) {
                if wanted == nil || MCP.messageID(message) == wanted { return message }
            }
        }
    }

    /// Terminate the child process. Safe to call more than once.
    public func close() {
        guard started else { return }
        process.terminate()
        started = false
    }
}

#endif
