import AppKit

enum CLI {
    static let usage = """
    用法：
      peek [-t 标题] [-c 对话名] 文件…   推到屏幕右上角的卡片，点卡片才打开（图片 / PDF / Markdown / HTML）
      peek --remote-settings   管理远程机器
      peek --list              列出 24 小时内的卡片
      peek --clear             全部清空
      peek --quit              退出后台的 Peek
    """

    static func main(_ args: [String]) -> Int32 {
        var title: String?
        var source: String?
        var paths: [String] = []
        var i = 0
        var optionsDone = false
        while i < args.count {
            let a = args[i]
            if !optionsDone {
                switch a {
                case "-h", "--help":
                    print(usage)
                    return 0
                case "-t", "--title", "-s", "--source", "-c", "--conversation":
                    guard i + 1 < args.count else { return fail("\(a) 后面要跟内容") }
                    switch a {
                    case "-t", "--title": title = args[i + 1]
                    case "-c", "--conversation": setenv("PEEK_CONVERSATION", args[i + 1], 1)
                    default: source = args[i + 1]
                    }
                    i += 2
                    continue
                case "--remote-settings":
                    return requestRemoteSettings()
                case "--list":
                    return list()
                case "--clear":
                    Paths.ensure()
                    Store.removeAll()
                    notify(Paths.changed)
                    print("已清空")
                    return 0
                case "--quit":
                    notify(Paths.quit)
                    return 0
                case "--debug":
                    let cmd = args[(i + 1)...].joined(separator: " ")
                    DistributedNotificationCenter.default().postNotificationName(
                        Paths.debug, object: nil, userInfo: ["cmd": cmd], deliverImmediately: true)
                    return 0
                case "--selftest":
                    return SelfTest.run()
                case "--":
                    optionsDone = true
                    i += 1
                    continue
                default:
                    if a.hasPrefix("-") && a.count > 1 { return fail("不认识的参数：\(a)\n\(usage)") }
                }
            }
            paths.append(a)
            i += 1
        }
        guard !paths.isEmpty else {
            print(usage)
            return 64
        }
        return push(paths, title: title, source: source)
    }

    // MARK: push

    static func push(_ paths: [String], title: String?, source: String?, origin: PeekOrigin? = nil, preserveGroups: Bool = false) -> Int32 {
        do {
            _ = try publish(paths, title: title, source: source, origin: origin, preserveGroups: preserveGroups)
            return 0
        } catch { return fail("推送失败：\(error.localizedDescription)") }
    }

    /// Returns the identity created by this atomic publication, independently of
    /// other CLI processes adding or removing cards in the shared store.
    static func publish(_ paths: [String], title: String?, source: String?, origin: PeekOrigin? = nil,
                        preserveGroups: Bool = false, cancellation: RemoteCancellation? = nil) throws -> PeekItem {
        try cancellation?.check()

        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        var sources: [URL] = []
        for p in paths {
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath, relativeTo: cwd).standardizedFileURL
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { throw RemoteError.invalid("找不到文件：\(p)") }
            guard !isDir.boolValue else { throw RemoteError.invalid("这是文件夹，不是文件：\(p)") }
            sources.append(url)
        }

        Paths.ensure()
        let now = Date()
        let id = Store.makeID(now)
        let stage = Paths.incoming.appendingPathComponent(id, isDirectory: true)
        let filesDir = stage.appendingPathComponent("files", isDirectory: true)
        let published: PeekItem
        do {
            try fm.createDirectory(at: filesDir, withIntermediateDirectories: true)
            var files: [PeekFile] = []
            var used = Set<String>()
            for (index, url) in sources.enumerated() {
                try cancellation?.check()
                var stored = url.lastPathComponent
                var n = 2
                while used.contains(stored.lowercased()) {
                    let base = (url.lastPathComponent as NSString).deletingPathExtension
                    let ext = url.pathExtension
                    stored = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
                    n += 1
                }
                used.insert(stored.lowercased())
                if preserveGroups {
                    let group = String(index)
                    try fm.copyItem(at: url.deletingLastPathComponent(), to: filesDir.appendingPathComponent(group))
                    stored = group + "/" + url.lastPathComponent
                } else {
                    // copyItem clones on APFS: instant and no extra space.
                    try fm.copyItem(at: url, to: filesDir.appendingPathComponent(stored))
                }
                files.append(PeekFile(name: url.lastPathComponent, stored: stored, original: url.path))
                if !preserveGroups { Assets.copy(for: url, into: filesDir) }
            }
            let title = title ?? (sources.count == 1 ? Assets.title(of: sources[0]) : nil)
            var item = PeekItem(id: id, created: now, title: title,
                                source: source ?? detectSource(cwd), files: files)
            item.origin = origin ?? Origin.detect()
            try Store.save(item, in: stage)
            // Cancellation and the final rename share a lock. Cancellation before
            // this boundary discards staging; after it the complete card exists.
            let commit = { try fm.moveItem(at: stage, to: Paths.items.appendingPathComponent(id, isDirectory: true)) }
            if let cancellation { try cancellation.commit(commit) } else { try commit() }
            published = item
        } catch {
            try? fm.removeItem(at: stage)
            throw error
        }

        if ProcessInfo.processInfo.environment["PEEK_HOME"] == nil {
            notify(Paths.changed)
            ensureAppRunning()
        }
        print("已推到右上角卡片：" + sources.map(\.lastPathComponent).joined(separator: "、"))
        return published
    }

    /// Project name for the card's second line: PEEK_SOURCE, else the enclosing
    /// git repo, else the current folder.
    static func detectSource(_ cwd: URL) -> String {
        let env = ProcessInfo.processInfo.environment
        if let s = env["PEEK_SOURCE"], !s.isEmpty { return s }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        var dir = cwd.standardizedFileURL
        while dir.path != "/" && dir.path != home {
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) { return dir.lastPathComponent }
            dir = dir.deletingLastPathComponent()
        }
        if cwd.standardizedFileURL.path == home { return "~" }
        return cwd.lastPathComponent
    }

    // MARK: app process

    static func appBundleURL() -> URL? {
        // Works whether we're run as …/Peek.app/Contents/MacOS/Peek or via the ~/bin/peek symlink.
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let real = (Bundle.main.executableURL ?? exe).resolvingSymlinksInPath()
        for candidate in [real, exe] {
            let app = candidate.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            if app.pathExtension == "app" { return app }
        }
        let installed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Peek.app")
        return FileManager.default.fileExists(atPath: installed.path) ? installed : nil
    }

    // The marker is written before launching. A notification handles an already
    // running app; a startup read handles notifications sent before registration.
    static var settingsRequest: URL { Paths.root.appendingPathComponent("remote-settings-request") }
    static let settingsNotification = Notification.Name("com.terryops.peek.remote-settings")
    static func requestRemoteSettings() -> Int32 {
        Paths.ensure()
        do { try Data(UUID().uuidString.utf8).write(to: settingsRequest, options: .atomic) }
        catch { return fail("无法打开远程机器：\(error.localizedDescription)") }
        notify(settingsNotification)
        if ProcessInfo.processInfo.environment["PEEK_HOME"] == nil { ensureAppRunning() }
        return 0
    }
    static func consumeSettingsRequest() -> Bool {
        guard FileManager.default.fileExists(atPath: settingsRequest.path) else { return false }
        do { try FileManager.default.removeItem(at: settingsRequest); return true }
        catch { return false }
    }

    static func ensureAppRunning() {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: Paths.bundleID).isEmpty { return }
        // Preferred: the LaunchAgent (keeps it alive, starts at login).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", "gui/\(getuid())/\(Paths.bundleID)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            p.waitUntilExit()
            if p.terminationStatus == 0 { return }
        }
        // Fallback: launch the bundle directly, in the background.
        guard let app = appBundleURL() else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.addsToRecentItems = false
        cfg.arguments = ["--app"]
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: app, configuration: cfg) { _, _ in done.signal() }
        _ = done.wait(timeout: .now() + 3)
    }

    static func notify(_ name: Notification.Name) {
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: nil, deliverImmediately: true)
    }

    // MARK: list

    static func list() -> Int32 {
        let items = Store.loadAll()
        if items.isEmpty {
            print("没有卡片")
            return 0
        }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        for item in items {
            let mark = item.seen ? " " : "●"
            let state = item.dismissed ? "（已收起）" : ""
            let extra = item.files.count > 1 ? " +\(item.files.count - 1)" : ""
            print("\(mark) \(f.string(from: item.created))  \(item.source)  \(item.displayTitle)\(extra)\(state)")
        }
        return 0
    }

    static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(("peek: " + message + "\n").data(using: .utf8)!)
        return 1
    }
}
