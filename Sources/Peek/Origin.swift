import Foundation
import Darwin

/// Figures out which conversation is calling `peek` (CLI side, runs inside the
/// Claude Code Bash tool). Everything here is best-effort and fast.
enum Origin {
    static func detect() -> PeekOrigin? {
        let env = ProcessInfo.processInfo.environment
        var o = PeekOrigin()
        o.sessionID = env["CLAUDE_CODE_SESSION_ID"]?.nonEmpty
        if let rex = env["REX_SESSION"]?.nonEmpty {
            o.rexSession = rex
            o.rexBlock = env["REX_BLOCK"]?.nonEmpty
            o.rexBin = which("rex")
        }
        let prompts: (first: String?, last: String?) = o.sessionID.map(historyPrompts) ?? (nil, nil)
        o.prompt = prompts.last.map { clean($0, max: 160) }
        // Several conversations can share one Rex session, so its label is only a last resort;
        // a pane you renamed, or the conversation's first prompt, is specific to this one.
        o.conversation = env["PEEK_CONVERSATION"]?.nonEmpty
            ?? claudeSessionName(pid: env["CLAUDE_PID"])
            ?? rexBlockLabel(o.rexBlock, bin: o.rexBin)
            ?? prompts.first.map { clean($0, max: 26) }
            ?? rexLabel(o.rexSession, bin: o.rexBin)
        o.terminalBundle = o.rexSession != nil ? "com.superlogical.rex" : terminalBundle()
        if o.sessionID == nil && o.conversation == nil && o.terminalBundle == nil { return nil }
        return o
    }

    static func clean(_ s: String, max: Int) -> String {
        let flat = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return flat.count > max ? String(flat.prefix(max)) + "…" : flat
    }

    /// A name the user gave the session with /rename (auto-derived names like "git-a1" don't count).
    private static func claudeSessionName(pid: String?) -> String? {
        guard let pid, !pid.isEmpty else { return nil }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions/\(pid).json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = (obj["name"] as? String)?.nonEmpty else { return nil }
        let source = obj["nameSource"] as? String ?? ""
        return source == "derived" ? nil : name
    }

    private static func rexLabel(_ session: String?, bin: String?) -> String? {
        guard let session, let bin else { return nil }
        guard let out = run(bin, ["session", "list", "--json"], timeout: 1),
              let obj = try? JSONSerialization.jsonObject(with: out) as? [String: Any],
              let list = obj["sessions"] as? [[String: Any]] else { return nil }
        return list.first { ($0["session_id"] as? String) == session }.flatMap { ($0["label"] as? String)?.nonEmpty }
    }

    private static func rexBlockLabel(_ block: String?, bin: String?) -> String? {
        guard let block, let bin,
              let out = run(bin, ["block", "list", "--json"], timeout: 1),
              let obj = try? JSONSerialization.jsonObject(with: out) as? [String: Any],
              let list = obj["blocks"] as? [[String: Any]],
              let label = list.first(where: { ($0["block_id"] as? String) == block }).flatMap({ ($0["label"] as? String)?.nonEmpty })
        else { return nil }
        return ["shell", "zsh", "bash", "fish", "terminal", "claude"].contains(label.lowercased()) ? nil : label
    }

    /// First and latest prompts typed in this session (from ~/.claude/history.jsonl).
    private static func historyPrompts(_ session: String) -> (first: String?, last: String?) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/history.jsonl")
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
              let needle = "\"sessionId\":\"\(session)\"".data(using: .utf8) else { return (nil, nil) }
        func prompt(at r: Range<Data.Index>) -> String? {
            let start = data[..<r.lowerBound].lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
            let end = data[r.upperBound...].firstIndex(of: 0x0A) ?? data.endIndex
            guard let obj = try? JSONSerialization.jsonObject(with: data[start..<end]) as? [String: Any],
                  let text = (obj["display"] as? String)?.nonEmpty, !text.hasPrefix("/") else { return nil }
            return text
        }
        // Latest: scan back from the end, skipping slash commands.
        var last: String?
        var upper = data.endIndex
        while last == nil, let r = data.range(of: needle, options: .backwards, in: data.startIndex..<upper) {
            last = prompt(at: r)
            upper = r.lowerBound
        }
        var first: String?
        var lower = data.startIndex
        while first == nil, let r = data.range(of: needle, in: lower..<data.endIndex) {
            first = prompt(at: r)
            lower = r.upperBound
        }
        return (first, last)
    }

    /// Walks up the process tree to the GUI app we're running inside (Ghostty, Terminal, VS Code…).
    private static func terminalBundle() -> String? {
        var pid = getppid()
        for _ in 0..<16 where pid > 1 {
            if let path = processPath(pid), let r = path.range(of: ".app/") {
                let app = URL(fileURLWithPath: String(path[..<r.lowerBound]) + ".app")
                if let id = Bundle(url: app)?.bundleIdentifier { return id }
            }
            guard let parent = parentPID(pid), parent != pid else { break }
            pid = parent
        }
        return nil
    }

    private static func processPath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    private static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    static func which(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static func run(_ bin: String, _ args: [String], timeout: TimeInterval) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(5_000) }
        if p.isRunning { p.terminate(); return nil }
        return pipe.fileHandleForReading.readDataToEndOfFile()
    }
}
