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
            func send(_ request: [String: Any]) async throws -> Data {
                let name = (request["params"] as? [String: Any])?["name"] as? String ?? "?"
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
}
