import AppKit

final class App: NSObject, NSApplicationDelegate {
    static func run() {
        let app = NSApplication.shared
        let delegate = App()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    private(set) var items: [PeekItem] = []
    let cards = CardStack()
    let menu = StatusMenu()
    private var recentPanel: RecentPanel?
    @MainActor private lazy var remoteConnections = RemoteConnections()
    @MainActor private lazy var remoteSettings = RemoteSettings(connections: remoteConnections)
    private var watcher: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?
    private var lockFD: Int32 = -1
    /// Debug: log instead of really opening / revealing.
    private var dryRun = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Paths.ensure()
        guard takeLock() else {
            NSLog("Peek already running")
            exit(0)
        }
        cards.app = self
        menu.app = self
        Viewer.shared.app = self
        reload()
        watch()
        Hotkeys.shared.start([
            .open: { [weak self] in self?.openNewest() },
            .recent: { [weak self] in self?.toggleRecent() },
            .tuck: { [weak self] in self?.toggleTuck() },
            .closeAll: { [weak self] in self?.dismissAll() },
        ])

        remoteConnections.start()
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(remoteControlNotification), name: RemoteControl.notification, object: nil,
                        suspensionBehavior: .deliverImmediately)
        remoteControlNotification()
        dnc.addObserver(self, selector: #selector(settingsNotification), name: CLI.settingsNotification, object: nil,
                        suspensionBehavior: .deliverImmediately)
        settingsNotification()
        dnc.addObserver(self, selector: #selector(changedNotification), name: Paths.changed, object: nil,
                        suspensionBehavior: .deliverImmediately)
        if ProcessInfo.processInfo.environment["PEEK_DEBUG"] == "1" {
            dnc.addObserver(self, selector: #selector(debugNotification(_:)), name: Paths.debug, object: nil,
                            suspensionBehavior: .deliverImmediately)
        }
        dnc.addObserver(self, selector: #selector(quitNotification), name: Paths.quit, object: nil,
                        suspensionBehavior: .deliverImmediately)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
            self?.cards.relayout()
        }
        workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.cards.relayout()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.cards.relayout()
        }
        // Daily cleanup: anything older than 24h goes, checked every 20 minutes.
        let t = Timer(timeInterval: 20 * 60, repeats: true) { [weak self] _ in self?.reload() }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
    }

    private func takeLock() -> Bool {
        lockFD = Darwin.open(Paths.lock.path, O_CREAT | O_RDWR, 0o644)
        return lockFD >= 0 && flock(lockFD, LOCK_EX | LOCK_NB) == 0
    }

    // MARK: store

    /// Disk is the source of truth; every change ends up here.
    func reload() {
        Store.cleanup()
        items = Store.loadAll()
        let live = Set(items.map(\.id))
        Thumbs.prune(keeping: live)
        refresh()
    }

    func refresh() {
        cards.sync(items)
        menu.update(items)
        if let recentPanel, recentPanel.isVisible { recentPanel.update(items) }
        Viewer.shared.itemsChanged(items)
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work)
    }

    private func watch() {
        watcher?.cancel()
        let fd = Darwin.open(Paths.items.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            if !src.data.intersection([.delete, .rename]).isEmpty {
                // Folder itself was removed (cache wiped): recreate and re-watch.
                Paths.ensure()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.watch() }
            }
            self.scheduleReload()
        }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        watcher = src
    }

    func applicationWillTerminate(_ notification: Notification) { remoteConnections.stop() }
    @MainActor func showRemoteSettings() { remoteSettings.present() }
    @MainActor @objc private func settingsNotification() {
        if CLI.consumeSettingsRequest() { showRemoteSettings() }
    }

    @MainActor @objc private func remoteControlNotification() {
        RemoteControl.consume(using: remoteConnections)
    }

    @objc private func changedNotification() { scheduleReload() }
    @objc private func quitNotification() { NSApp.terminate(nil) }

    private func item(_ id: String) -> PeekItem? { items.first { $0.id == id } }

    private func commit(_ item: PeekItem, sync: Bool = true) {
        try? Store.save(item)
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item }
        if sync { refresh() }
    }

    // MARK: actions

    /// Opens in Peek's own viewer (never Preview), zooming out of the card.
    @discardableResult
    func open(_ id: String, from rect: NSRect? = nil, returningTo window: NSWindow? = nil) -> Bool {
        guard var item = item(id),
              item.urls.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return false }
        if dryRun { log("open \(item.urls.map(\.lastPathComponent))") }
        Viewer.shared.show(item, from: rect, returningTo: window)
        item.seen = true
        item.lastOpened = Date()
        commit(item)
        return true
    }

    private func pick(_ item: PeekItem, _ only: Int?) -> [Int] {
        if let only, only < item.files.count { return [only] }
        return Array(item.files.indices)
    }

    func reveal(_ id: String, only: Int? = nil) {
        guard let item = item(id) else { return }
        let urls = pick(item, only).map { item.revealURLs[$0] }
        if dryRun { return log("reveal \(urls.map(\.path))") }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// File URLs plus image data, so it pastes into Finder, chat apps and editors alike.
    @discardableResult
    func copy(_ id: String, only: Int? = nil) -> Bool {
        guard let item = item(id), !item.files.isEmpty else { return false }
        let urls = pick(item, only).map { item.urls[$0] }
        let pb = NSPasteboard.general
        pb.clearContents()
        let writers: [NSPasteboardItem] = urls.map { url in
            let p = NSPasteboardItem()
            p.setString(url.absoluteString, forType: .fileURL)
            if urls.count == 1, let img = NSImage(contentsOf: url), let tiff = img.tiffRepresentation {
                p.setData(tiff, forType: .tiff)
                if url.pathExtension.lowercased() == "png", let data = try? Data(contentsOf: url) {
                    p.setData(data, forType: .png)
                }
            }
            return p
        }
        guard pb.writeObjects(writers) else { return false }
        if dryRun { log("copy \(urls.map(\.lastPathComponent))") }
        return true
    }

    /// Focus the local Rex session and, when recorded, the pane that sent the card.
    /// Going back means you've looked: the files count as read, and `dismissCard`
    /// also takes the card off screen (used when jumping straight from a card).
    func jump(_ id: String, dismissCard: Bool = false) {
        guard var item = item(id), let origin = item.origin, let target = origin.jumpTarget else { return }
        item.seen = true
        if dismissCard { item.dismissed = true }
        commit(item)
        if dryRun { return log("jump \(target.session) dismissCard=\(dismissCard)") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: target.executable)
        p.arguments = ["focus", "-s", target.session] + (origin.rexBlock?.nonEmpty.map { [$0] } ?? [])
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Origin.rexBundleID) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        }
    }

    /// ⌥⌘P: open the newest card in the viewer.
    func openNewest() {
        let card = cards.cards.first
        guard let id = card?.id ?? items.first?.id else { NSSound.beep(); return }
        open(id, from: card?.shown == true ? card?.panel.frame : nil)
    }

    /// ↑ / ↓ in the viewer: walk the history, newest first.
    func openNeighbor(_ id: String, _ offset: Int, returningTo window: NSWindow? = nil) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard items.indices.contains(j) else { NSSound.beep(); return }
        open(items[j].id, returningTo: window)
    }

    func toggleTuck() {
        cards.mode == .tucked ? cards.untuck() : cards.tuck()
    }

    private func toggleRecent() {
        if let recentPanel, recentPanel.isKeyWindow {
            recentPanel.close()
            return
        }
        if Prefs.recentShortcutBehavior == .singleUnread, let item = RecentPanel.singleUnread(in: items) {
            let card = cards.cards.first { $0.id == item.id && $0.shown }
            let overview = recentPanel?.isVisible == true ? recentPanel : nil
            if open(item.id, from: card?.panel.frame, returningTo: overview) { return }
        }
        showRecentOverview()
    }

    func showRecentOverview() {
        let panel = recentPanel ?? RecentPanel { [weak self] id, panel in
            self?.open(id, from: panel.frame, returningTo: panel)
        }
        recentPanel = panel
        panel.present(items)
    }

    func setStyle(_ style: CardStyle) {
        guard style != Prefs.style else { return }
        Prefs.style = style
        cards.restyle()
    }

    func setStacking(_ mode: StackMode) {
        Prefs.stacking = mode
        cards.relayout()
    }

    func dismiss(_ id: String) {
        guard var item = item(id), !item.dismissed else { return }
        item.dismissed = true
        commit(item)
    }

    /// Called from inside a sync, so it must not trigger another one.
    func markDismissed(_ id: String) {
        guard var item = item(id), !item.dismissed else { return }
        item.dismissed = true
        commit(item, sync: false)
    }

    func dismissAll() {
        for var item in items where !item.dismissed {
            item.dismissed = true
            commit(item, sync: false)
        }
        refresh()
    }

    func clearAll() {
        Store.removeAll()
        reload()
    }

    // MARK: debug hooks (peek --debug …), used by the test script

    private func log(_ s: String) {
        let line = "\(Date().timeIntervalSince1970) \(s)\n"
        let url = Paths.root.appendingPathComponent("debug.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @objc private func debugNotification(_ n: Notification) {
        let parts = ((n.userInfo?["cmd"] as? String) ?? "").split(separator: " ").map(String.init)
        guard let cmd = parts.first else { return }
        let index = parts.count > 1 ? Int(parts[1]) : nil
        let card = index.flatMap { cards.cards.indices.contains($0) ? cards.cards[$0] : nil }
        switch cmd {
        case "dry": dryRun = parts.count < 2 || parts[1] != "off"
        case "click": card?.open()
        case "option-click": card?.reveal()
        case "copy": card?.copyFiles()
        case "close": card?.close(all: false)
        case "closeall": dismissAll()
        case "hover": card?.setHover(parts.count < 3 || parts[2] != "off", close: parts.count > 3 && parts[3] == "close")
        case "swipe":
            if let card, parts.count > 2, let dx = Double(parts[2]) {
                card.applySwipe(CGFloat(dx))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { card.endSwipe() }
            }
        case "clear": clearAll()
        case "style": if parts.count > 1, let st = CardStyle(rawValue: parts[1]) { setStyle(st) }
        case "stacking": if parts.count > 1, let st = StackMode(rawValue: parts[1]) { setStacking(st) }
        case "view":
            if let card {
                // "nokey": don't take the keyboard (tests while someone is typing elsewhere).
                Viewer.shared.takesKey = !(parts.count > 2 && parts[2] == "nokey")
                open(card.id, from: card.panel.frame)
                Viewer.shared.takesKey = true
            }
        case "viewer-jump": Viewer.shared.jumpBack()
        case "hotkey":
            switch parts.count > 1 ? parts[1] : "" {
            case "open": Hotkeys.shared.fire(.open)
            case "recent": Hotkeys.shared.fire(.recent)
            case "tuck": Hotkeys.shared.fire(.tuck)
            case "closeall": Hotkeys.shared.fire(.closeAll)
            default: break
            }
        case "vkey":
            // Simulated key in the viewer: vkey <keyCode> [cmd|shift]
            if parts.count > 1, let code = UInt16(parts[1]), let win = NSApp.windows.first(where: { $0 is ViewerWindow }) {
                let flags: NSEvent.ModifierFlags = parts.count > 2 ? (parts[2] == "cmd" ? .command : .shift) : []
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                            windowNumber: win.windowNumber, context: nil, characters: "",
                                            charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) {
                    win.keyDown(with: e)
                }
            }
        case "viewer-close": NSApp.windows.first(where: { $0 is ViewerWindow })?.performClose(nil)
        case "viewer-step": Viewer.shared.step(1)
        case "viewer-swipe":
            // Inspect a drag with "viewer-swipe -80 hold", then finish or cancel it.
            if parts.count > 1, let dx = Double(parts[1]), dx.isFinite {
                let viewer = Viewer.shared
                viewer.cancelSwipeAnimation()
                viewer.updateSwipe(CGFloat(dx))
                let action = parts.count > 2 ? parts[2] : "end"
                if action != "hold" {
                    let commit = action != "cancel" && abs(dx) >= 64
                    viewer.finishSwipe(commit ? (dx < 0 ? 1 : -1) : nil)
                }
            }
        case "viewer-compare": Viewer.shared.toggleCompare()
        case "jump": card?.jump()
        case "tuck": cards.tuck()
        case "untuck": cards.untuck()
        case "enter": cards.pointerEntered(force: true)
        default: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (cmd == "dump" ? 0 : 0.9)) { [weak self] in self?.dump() }
    }

    private func dump() {
        let info: [String: Any] = [
            "stack": cards.snapshot(),
            "items": items.count,
            "unread": items.filter { !$0.seen }.count,
            "menu": menu.snapshot(),
            "pid": ProcessInfo.processInfo.processIdentifier,
            "mouse": NSStringFromPoint(NSEvent.mouseLocation),
            "viewer": Viewer.shared.snapshot(),
            "hotkeys": Hotkeys.shared.active.map { "\($0.key.defaultsKey)=\($0.value.display)" }.sorted(),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Paths.debugOut, options: .atomic)
        }
    }
}
