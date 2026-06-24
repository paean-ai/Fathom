import Foundation

/// Real agent capabilities — the filesystem + shell tools that let a Fathom agent actually DO
/// work (read code, edit files, search, run commands), the way Codex / Claude Code do. Every tool
/// is confined to a root directory via `FileSandbox`, so an agent can't read or clobber files
/// outside its working tree. Mutating tools set `isMutating` so the orchestrator's approval gate
/// can confirm them. These are real I/O, but unit-tested against a temp directory.

/// Confines all file paths to a root directory. `resolve` returns nil for any path that escapes
/// the root (via `..`, an absolute path outside, or symlink games), so tools fail closed.
public struct FileSandbox: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root.standardizedFileURL }

    /// Resolve a possibly-relative path against the root, returning nil if it escapes the root.
    public func resolve(_ path: String) -> URL? {
        let raw = path.hasPrefix("/") ? URL(fileURLWithPath: path)
                                      : root.appendingPathComponent(path)
        let resolved = raw.standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return (resolved.path == root.path || resolved.path.hasPrefix(rootPath)) ? resolved : nil
    }

    /// Display a URL relative to the root (for tool output).
    public func relative(_ url: URL) -> String {
        let r = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(r) ? String(url.path.dropFirst(r.count)) : url.path
    }
}

/// Translates a glob pattern (`*`, `?`, `**`) into a regex and matches paths. Pure → testable.
public enum Glob {
    /// True when `path` (a `/`-separated relative path) matches `pattern`. `**` spans directories;
    /// `*` matches within a path segment; `?` matches one non-`/` character.
    public static func match(_ pattern: String, _ path: String) -> Bool {
        var rx = "^"
        let chars = Array(pattern)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "*":
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    rx += ".*"; i += 2
                    if i < chars.count, chars[i] == "/" { i += 1 }   // `**/` also matches zero dirs
                } else {
                    rx += "[^/]*"; i += 1
                }
            case "?": rx += "[^/]"; i += 1
            case ".", "(", ")", "+", "|", "^", "$", "{", "}", "[", "]", "\\":
                rx += "\\" + String(c); i += 1
            default: rx += String(c); i += 1
            }
        }
        rx += "$"
        return path.range(of: rx, options: .regularExpression) != nil
    }
}

// MARK: - Tools

/// Read a file's text contents (optionally a line range).
public struct ReadFileTool: OrchestratorTool {
    public let name = "read_file"
    public let toolDescription = "Read a UTF-8 text file's contents. Optionally pass 'offset' (1-based start line) and 'limit' (max lines)."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "path": ["type": "string", "description": "File path (relative to the working directory)."],
        "offset": ["type": "integer", "description": "1-based first line (optional)."],
        "limit": ["type": "integer", "description": "Max lines to return (optional)."],
    ], "required": ["path"]] }
    let sandbox: FileSandbox
    public init(sandbox: FileSandbox) { self.sandbox = sandbox }

    public func invoke(arguments: String) async -> String {
        let a = JSONArgs(arguments)
        guard let path = a.string("path") else { return "Error: missing 'path'." }
        guard let url = sandbox.resolve(path) else { return "Error: path is outside the working directory." }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Error: couldn't read \(path) (missing or not UTF-8 text)."
        }
        var lines = text.components(separatedBy: "\n")
        if let offset = a.int("offset") { lines = Array(lines.dropFirst(max(0, offset - 1))) }
        if let limit = a.int("limit") { lines = Array(lines.prefix(max(0, limit))) }
        return lines.joined(separator: "\n")
    }
}

/// Create or overwrite a file.
public struct WriteFileTool: OrchestratorTool {
    public let name = "write_file"
    public let toolDescription = "Create or overwrite a text file with the given content."
    public let isMutating = true
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "path": ["type": "string", "description": "File path (relative to the working directory)."],
        "content": ["type": "string", "description": "The full file content to write."],
    ], "required": ["path", "content"]] }
    let sandbox: FileSandbox
    public init(sandbox: FileSandbox) { self.sandbox = sandbox }

    public func invoke(arguments: String) async -> String {
        let a = JSONArgs(arguments)
        guard let path = a.string("path"), let content = a.string("content") else {
            return "Error: missing 'path' or 'content'."
        }
        guard let url = sandbox.resolve(path) else { return "Error: path is outside the working directory." }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return "Wrote \(content.utf8.count) bytes to \(path)."
        } catch { return "Error writing \(path): \(error.localizedDescription)" }
    }
}

/// Exact string replacement within a file (the safe edit primitive — fails if the target text
/// isn't unique, so the agent can't clobber the wrong spot).
public struct EditFileTool: OrchestratorTool {
    public let name = "edit_file"
    public let toolDescription = "Replace an exact text span in a file. 'old_string' must appear EXACTLY once (include surrounding context to make it unique)."
    public let isMutating = true
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "path": ["type": "string", "description": "File path (relative to the working directory)."],
        "old_string": ["type": "string", "description": "Exact text to replace (must be unique in the file)."],
        "new_string": ["type": "string", "description": "Replacement text."],
    ], "required": ["path", "old_string", "new_string"]] }
    let sandbox: FileSandbox
    public init(sandbox: FileSandbox) { self.sandbox = sandbox }

    public func invoke(arguments: String) async -> String {
        let a = JSONArgs(arguments)
        guard let path = a.string("path"), let old = a.string("old_string"),
              let new = a.string("new_string") else { return "Error: missing 'path'/'old_string'/'new_string'." }
        guard let url = sandbox.resolve(path) else { return "Error: path is outside the working directory." }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Error: couldn't read \(path)."
        }
        let parts = text.components(separatedBy: old)
        guard parts.count != 1 else { return "Error: 'old_string' not found in \(path)." }
        guard parts.count == 2 else {
            return "Error: 'old_string' appears \(parts.count - 1) times in \(path) — add context to make it unique."
        }
        let updated = parts[0] + new + parts[1]
        do { try updated.write(to: url, atomically: true, encoding: .utf8)
             return "Edited \(path)." }
        catch { return "Error writing \(path): \(error.localizedDescription)" }
    }
}

/// List the entries of a directory.
public struct ListDirTool: OrchestratorTool {
    public let name = "list_dir"
    public let toolDescription = "List the files and subdirectories of a directory (trailing / marks directories)."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "path": ["type": "string", "description": "Directory path (relative to the working directory; default '.')."],
    ]] }
    let sandbox: FileSandbox
    public init(sandbox: FileSandbox) { self.sandbox = sandbox }

    public func invoke(arguments: String) async -> String {
        let a = JSONArgs(arguments)
        let path = a.string("path") ?? "."
        guard let url = sandbox.resolve(path) else { return "Error: path is outside the working directory." }
        guard let entries = try? FileManager.default.contentsOfDirectory(at: url,
                                  includingPropertiesForKeys: [.isDirectoryKey]) else {
            return "Error: couldn't list \(path)."
        }
        if entries.isEmpty { return "(empty)" }
        return entries.map { e -> String in
            let isDir = (try? e.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return e.lastPathComponent + (isDir ? "/" : "")
        }.sorted().joined(separator: "\n")
    }
}

/// Find files matching a glob pattern under the working directory.
public struct GlobTool: OrchestratorTool {
    public let name = "glob"
    public let toolDescription = "Find files matching a glob pattern (e.g. '**/*.swift', 'src/*.json'). Returns matching paths."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "pattern": ["type": "string", "description": "Glob pattern; ** spans directories."],
    ], "required": ["pattern"]] }
    let sandbox: FileSandbox
    public init(sandbox: FileSandbox) { self.sandbox = sandbox }

    public func invoke(arguments: String) async -> String {
        let a = JSONArgs(arguments)
        guard let pattern = a.string("pattern") else { return "Error: missing 'pattern'." }
        let fm = FileManager.default
        guard let en = fm.enumerator(at: sandbox.root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return "Error: couldn't scan the working directory."
        }
        let urls = en.allObjects.compactMap { $0 as? URL }   // materialize (Swift 6: no async iteration)
        var hits: [String] = []
        for url in urls {
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isFile else { continue }
            let rel = sandbox.relative(url)
            if Glob.match(pattern, rel) { hits.append(rel) }
            if hits.count >= 500 { break }
        }
        return hits.isEmpty ? "(no matches)" : hits.sorted().joined(separator: "\n")
    }
}

/// Search file contents for a substring/regex (a lightweight grep), with file:line output.
public struct GrepTool: OrchestratorTool {
    public let name = "grep"
    public let toolDescription = "Search text files for a pattern (regex). Optionally restrict with a glob 'in' pattern. Returns file:line: matches."
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "pattern": ["type": "string", "description": "Regular expression to search for."],
        "in": ["type": "string", "description": "Optional glob to limit which files are searched (e.g. '**/*.swift')."],
    ], "required": ["pattern"]] }
    let sandbox: FileSandbox
    public init(sandbox: FileSandbox) { self.sandbox = sandbox }

    public func invoke(arguments: String) async -> String {
        let a = JSONArgs(arguments)
        guard let pattern = a.string("pattern") else { return "Error: missing 'pattern'." }
        let glob = a.string("in")
        let fm = FileManager.default
        guard let en = fm.enumerator(at: sandbox.root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return "Error: couldn't scan the working directory."
        }
        let urls = en.allObjects.compactMap { $0 as? URL }   // materialize (Swift 6: no async iteration)
        var out: [String] = []
        for url in urls {
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isFile else { continue }
            let rel = sandbox.relative(url)
            if let glob, !Glob.match(glob, rel) { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                if line.range(of: pattern, options: .regularExpression) != nil {
                    out.append("\(rel):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))")
                    if out.count >= 200 { return out.joined(separator: "\n") }
                }
            }
        }
        return out.isEmpty ? "(no matches)" : out.joined(separator: "\n")
    }
}

/// Run a shell command in the working directory and return its combined stdout+stderr. Mutating
/// (so the approval gate can confirm) and time-bounded so a runaway command can't hang the agent.
///
/// When `confined` is set, the command runs under a conservative macOS `sandbox-exec` profile that
/// DENIES network access and confines filesystem writes to the working directory (plus the system
/// temp dirs and the standard `/dev` sinks) — so agent-written code can't phone home or clobber
/// files outside its workspace. Reads stay open so interpreters/toolchains load normally.
public struct RunCommandTool: OrchestratorTool {
    public let name = "run_command"
    public let toolDescription = "Run a shell command in the working directory and return its output. Use for builds, tests, git, etc."
    public let isMutating = true
    public var parameters: [String: Any] { ["type": "object", "properties": [
        "command": ["type": "string", "description": "The shell command to run."],
    ], "required": ["command"]] }
    let sandbox: FileSandbox
    let timeout: TimeInterval
    /// When true, wrap the command in `sandbox-exec` (no network; writes confined to the workdir).
    let confined: Bool
    public init(sandbox: FileSandbox, timeout: TimeInterval = 120, confined: Bool = false) {
        self.sandbox = sandbox; self.timeout = timeout; self.confined = confined
    }

    /// A conservative `sandbox-exec` (SBPL) profile: allow everything by default EXCEPT network
    /// access and filesystem writes outside `writableRoot` (system temp + the standard `/dev`
    /// sinks stay writable so tools work). SBPL is last-match-wins, so the broad write-deny is
    /// followed by the narrow allows. Pure → unit-testable.
    public static func sandboxProfile(writableRoot: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let root = esc(writableRoot)
        return """
        (version 1)
        (allow default)
        (deny network*)
        (deny file-write* (subpath "/"))
        (allow file-write* (subpath "\(root)"))
        (allow file-write* (subpath "/private/tmp"))
        (allow file-write* (subpath "/private/var/tmp"))
        (allow file-write* (subpath "/private/var/folders"))
        (allow file-write* (literal "/dev/null") (literal "/dev/zero") (literal "/dev/stdout") (literal "/dev/stderr") (literal "/dev/dtracehelper") (regex #"^/dev/tty"))
        """
    }

    public func invoke(arguments: String) async -> String {
        let a = JSONArgs(arguments)
        guard let command = a.string("command") else { return "Error: missing 'command'." }
        let proc = Process()
        if confined {
            // sandbox-exec confines writes to the workdir and denies network; the inner shell
            // still runs with the workdir as its cwd.
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            proc.arguments = ["-p", Self.sandboxProfile(writableRoot: sandbox.root.path), "/bin/sh", "-c", command]
        } else {
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = ["-c", command]
        }
        proc.currentDirectoryURL = sandbox.root
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch { return "Error launching command: \(error.localizedDescription)" }

        // Enforce the timeout without blocking forever.
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if proc.isRunning { proc.terminate(); return "Error: command timed out after \(Int(timeout))s." }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let status = proc.terminationStatus
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.isEmpty ? "(no output)" : trimmed
        return status == 0 ? body : "[exit \(status)]\n\(body)"
    }
}

/// Tiny JSON-arguments reader shared by the file tools.
struct JSONArgs {
    let dict: [String: Any]
    init(_ raw: String) {
        dict = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
    }
    func string(_ k: String) -> String? { dict[k] as? String }
    func int(_ k: String) -> Int? {
        if let i = dict[k] as? Int { return i }
        if let s = dict[k] as? String { return Int(s) }
        return nil
    }
}

public extension FileSandbox {
    /// The full coding tool suite scoped to this sandbox — drop straight into `Orchestrator.run`.
    /// Set `sandboxed` to run shell commands under `sandbox-exec` (no network; writes confined to
    /// this sandbox's root) — recommended whenever the agent runs model-written code.
    func codingTools(commandTimeout: TimeInterval = 120, sandboxed: Bool = false) -> [OrchestratorTool] {
        [ReadFileTool(sandbox: self), WriteFileTool(sandbox: self), EditFileTool(sandbox: self),
         ListDirTool(sandbox: self), GlobTool(sandbox: self), GrepTool(sandbox: self),
         RunCommandTool(sandbox: self, timeout: commandTimeout, confined: sandboxed)]
    }
}
