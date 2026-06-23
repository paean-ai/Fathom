import XCTest
@testable import Fathom

final class MCPTests: XCTestCase {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    func testInitializeRequestShape() {
        let req = MCP.initializeRequest(id: 1)
        XCTAssertEqual(req["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(req["id"] as? Int, 1)
        XCTAssertEqual(req["method"] as? String, "initialize")
        let params = req["params"] as? [String: Any]
        XCTAssertEqual(params?["protocolVersion"] as? String, MCP.protocolVersion)
        XCTAssertEqual((params?["clientInfo"] as? [String: Any])?["name"] as? String, "Fathom")
    }

    func testCallToolRequestCarriesNameAndArgs() {
        let req = MCP.callToolRequest(id: 7, name: "read_file", arguments: ["path": "/tmp/x"])
        XCTAssertEqual(req["method"] as? String, "tools/call")
        let params = req["params"] as? [String: Any]
        XCTAssertEqual(params?["name"] as? String, "read_file")
        XCTAssertEqual((params?["arguments"] as? [String: Any])?["path"] as? String, "/tmp/x")
    }

    func testParseToolsList() {
        let body = data("""
        {"jsonrpc":"2.0","id":1,"result":{"tools":[
          {"name":"read_file","description":"Read a file","inputSchema":{"type":"object","properties":{"path":{"type":"string"}}}},
          {"name":"list_dir","description":"List a directory","inputSchema":{"type":"object"}}
        ]}}
        """)
        let tools = MCP.parseToolsList(body)
        XCTAssertEqual(tools.count, 2)
        XCTAssertEqual(tools.first?.name, "read_file")
        XCTAssertEqual((tools.first?.parameters["properties"] as? [String: Any])?.keys.contains("path"), true)
    }

    func testParseToolResultConcatsTextBlocks() {
        let body = data(#"{"result":{"content":[{"type":"text","text":"line 1"},{"type":"text","text":"line 2"}]}}"#)
        XCTAssertEqual(MCP.parseToolResult(body), "line 1\nline 2")
    }

    func testParseToolResultSurfacesError() {
        let body = data(#"{"error":{"code":-32601,"message":"Method not found"}}"#)
        XCTAssertEqual(MCP.parseToolResult(body), "Error: Method not found")
    }

    func testMCPToolBridgesToOrchestratorTool() async {
        // A mock transport that echoes the request back as a text result.
        struct EchoTransport: MCPTransport {
            func send(_ request: Data) async throws -> Data {
                let obj = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any]
                let name = (obj?["params"] as? [String: Any])?["name"] as? String ?? "?"
                return Data(#"{"result":{"content":[{"type":"text","text":"ran \#(name)"}]}}"#.utf8)
            }
        }
        let def = MCP.ToolDef(name: "read_file", description: "Read a file",
                              inputSchema: ["type": "object", "properties": ["path": ["type": "string"]]])
        let tool = MCPTool(def: def, transport: EchoTransport())
        XCTAssertEqual(tool.name, "read_file")
        XCTAssertTrue(tool.isMutating)
        let out = await tool.invoke(arguments: #"{"path":"/tmp/x"}"#)
        XCTAssertEqual(out, "ran read_file")
        // The bridged schema is the OpenAI-style function wrapper around the inputSchema.
        let fn = tool.schema["function"] as? [String: Any]
        XCTAssertEqual(fn?["name"] as? String, "read_file")
    }

    // MARK: stdio framing

    func testEncodeMessageIsNewlineTerminatedJSON() {
        let d = MCP.encodeMessage(["jsonrpc": "2.0", "id": 5, "method": "ping"])
        XCTAssertEqual(d.last, 0x0A)
        let obj = (try? JSONSerialization.jsonObject(with: d.dropLast())) as? [String: Any]
        XCTAssertEqual(obj?["id"] as? Int, 5)
        XCTAssertEqual(obj?["method"] as? String, "ping")
    }

    func testMessageIDExtractsIdAndSkipsNotifications() {
        XCTAssertEqual(MCP.messageID(data(#"{"jsonrpc":"2.0","id":42,"result":{}}"#)), 42)
        XCTAssertNil(MCP.messageID(data(#"{"jsonrpc":"2.0","method":"notify"}"#)))   // notification
        XCTAssertNil(MCP.messageID(data("not json")))
    }

    func testFramerReassemblesAcrossChunksAndSplitsLines() {
        var framer = MCP.MessageFramer()
        // A message split across two reads yields nothing until the newline arrives.
        XCTAssertTrue(framer.push(data(#"{"id":1,"#)).isEmpty)
        let first = framer.push(data("\"x\":true}\n"))
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(MCP.messageID(first[0]), 1)
        // Two messages plus a partial third in one chunk: two emitted, partial held.
        let batch = framer.push(data("{\"id\":2}\n{\"id\":3}\n{\"id\":4"))
        XCTAssertEqual(batch.map { MCP.messageID($0) }, [2, 3])
        // The held partial completes when its newline arrives.
        XCTAssertEqual(framer.push(data("}\n")).map { MCP.messageID($0) }, [4])
        // Blank lines carry no message.
        var blanks = MCP.MessageFramer()
        XCTAssertTrue(blanks.push(data("\n\n")).isEmpty)
    }

    // MARK: client connect-flow (mock transport)

    func testClientConnectRunsHandshakeAndBridgesTools() async throws {
        // A mock server: acks initialize, lists two tools, echoes tool calls.
        struct MockServer: MCPTransport {
            func send(_ request: Data) async throws -> Data {
                let req = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any] ?? [:]
                switch req["method"] as? String {
                case "initialize":
                    return Data(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{}}}"#.utf8)
                case "tools/list":
                    return Data(#"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"read_file","description":"Read","inputSchema":{"type":"object"}},{"name":"write_file","description":"Write","inputSchema":{"type":"object"}}]}}"#.utf8)
                case "tools/call":
                    let name = (req["params"] as? [String: Any])?["name"] as? String ?? "?"
                    return Data(#"{"result":{"content":[{"type":"text","text":"ran \#(name)"}]}}"#.utf8)
                default:
                    return Data(#"{"result":{}}"#.utf8)
                }
            }
        }
        let tools = try await MCPClient(transport: MockServer()).connect()
        XCTAssertEqual(tools.map(\.name), ["read_file", "write_file"])
        let out = await tools[0].invoke(arguments: #"{"path":"/tmp/x"}"#)
        XCTAssertEqual(out, "ran read_file")
    }

    // MARK: real stdio transport (round-trips a line through /bin/cat)

    func testStdioTransportRoundTripsThroughCat() async throws {
        // `cat` echoes stdin to stdout, so writing a well-formed JSON-RPC *response* line and reading
        // it back exercises the full write → frame → id-match path against a real Process + pipes.
        let cat = FileManager.default.fileExists(atPath: "/bin/cat") ? "/bin/cat" : "/usr/bin/cat"
        let transport = StdioMCPTransport(executable: cat)
        let echoed = try await transport.send(MCP.encode(["jsonrpc": "2.0", "id": 1, "result": ["ok": true]]))
        XCTAssertEqual(MCP.messageID(echoed), 1)
        let obj = (try? JSONSerialization.jsonObject(with: echoed)) as? [String: Any]
        XCTAssertEqual((obj?["result"] as? [String: Any])?["ok"] as? Bool, true)
        await transport.close()
    }
}
