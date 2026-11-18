import AppKit

/// Menu-bar history: everything from the last 24 hours, click to open again.
/// Remote management stays reachable even before the first card.
final class StatusMenu: NSObject, NSMenuDelegate {
    weak var app: App?
    private var status: NSStatusItem?
    private var items: [PeekItem] = []
    private let maxRows = 30
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    func update(_ items: [PeekItem]) {
        self.items = items
        let s = status ?? make()
        s.isVisible = true
        let unread = items.filter { !$0.seen }.count
        guard let button = s.button else { return }
        button.title = unread > 0 ? "\(unread)" : ""
        button.imagePosition = unread > 0 ? .imageLeading : .imageOnly
        button.setAccessibilityLabel(
            unread > 0
                ? L10n.tr("Peek，\(unread) 个未查看", "Peek, \(unread) unread")
                : "Peek"
        )
    }

    private func make() -> NSStatusItem {
        let s = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        s.autosaveName = "PeekStatus"
        if let button = s.button {
            let img = NSImage(systemSymbolName: "photo.stack", accessibilityDescription: "Peek")
            img?.isTemplate = true
            button.image = img
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        s.menu = menu
        status = s
        return s
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let placeholder = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        let revealLabel = L10n.tr("在访达中显示", "Reveal in Finder")

        for item in items.prefix(maxRows) {
            var sub = "\(item.conversationTitle) · \(Self.timeFormatter.string(from: item.created))"
            if item.files.count > 1 {
                sub += " · " + L10n.tr("\(item.files.count) 个文件", "\(item.files.count) files")
            }
            let icon = Thumbs.cached(item)?.first.map { Thumbs.menuIcon($0) } ?? placeholder
            if Thumbs.cached(item) == nil { Thumbs.load(item) { _ in } }

            let row = NSMenuItem(title: item.displayTitle, action: #selector(openRow(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = item.id
            if #available(macOS 14.4, *) {
                row.subtitle = sub
            } else {
                row.toolTip = sub
            }
            row.image = icon
            if !item.seen {
                row.attributedTitle = NSAttributedString(string: item.displayTitle, attributes: [
                    .font: NSFont.menuFont(ofSize: 0).withWeight(.semibold),
                ])
            }
            menu.addItem(row)

            // Hold ⌥ to reveal in Finder instead.
            let alt = NSMenuItem(title: item.displayTitle, action: #selector(revealRow(_:)), keyEquivalent: "")
            alt.target = self
            alt.representedObject = item.id
            if #available(macOS 14.4, *) {
                alt.subtitle = revealLabel
            } else {
                alt.title = "\(item.displayTitle) — \(revealLabel)"
            }
            alt.image = icon
            alt.isAlternate = true
            alt.keyEquivalentModifierMask = .option
            menu.addItem(alt)
        }

        if !items.isEmpty { menu.addItem(.separator()) }
        let remote = NSMenuItem(title: L10n.tr("远程机器…", "Remote Machines…"), action: #selector(remoteSettings), keyEquivalent: "")
        remote.target = self
        menu.addItem(remote)
        if !SystemIntegration.isCLIInstalledForCurrentBundle {
            let cli = NSMenuItem(title: L10n.tr("安装 peek 命令", "Install 'peek' Command"), action: #selector(installCLI), keyEquivalent: "")
            cli.target = self
            menu.addItem(cli)
        }
        let login = NSMenuItem(title: L10n.tr("登录时打开", "Launch at Login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SystemIntegration.launchAtLoginEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        let styles = NSMenu()
        for style in CardStyle.allCases {
            let it = NSMenuItem(title: style.label, action: #selector(pickStyle(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = style.rawValue
            it.state = Prefs.style == style ? .on : .off
            styles.addItem(it)
        }
        styles.addItem(.separator())
        let deck = NSMenuItem(title: L10n.tr("叠放", "Deck Stack"), action: #selector(toggleDeck), keyEquivalent: "")
        deck.target = self
        deck.state = Prefs.stacking == .deck ? .on : .off
        styles.addItem(deck)
        let styleRoot = NSMenuItem(title: L10n.tr("卡片样式", "Card Style"), action: nil, keyEquivalent: "")
        styleRoot.submenu = styles
        menu.addItem(styleRoot)

        let newest = NSMenuItem(title: L10n.tr("打开最新卡片", "Open Newest Card"), action: #selector(openNewest), keyEquivalent: "")
        newest.target = self
        Hotkeys.shared.decorate(newest, .open)
        menu.addItem(newest)
        if let stack = app?.cards, !stack.cards.isEmpty {
            let tucked = stack.mode == .tucked
            let toggleTitle = tucked
                ? L10n.tr("显示卡片", "Show Cards")
                : L10n.tr("暂时收起卡片", "Tuck Cards Aside")
            let toggle = NSMenuItem(title: toggleTitle, action: #selector(toggleTuck), keyEquivalent: "")
            toggle.target = self
            Hotkeys.shared.decorate(toggle, .tuck)
            menu.addItem(toggle)
            let closeAll = NSMenuItem(title: L10n.tr("全部关闭", "Close All"), action: #selector(closeAll), keyEquivalent: "")
            closeAll.target = self
            Hotkeys.shared.decorate(closeAll, .closeAll)
            menu.addItem(closeAll)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: L10n.tr("全部清空", "Clear All"), action: #selector(clearAll), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        let quit = NSMenuItem(title: L10n.tr("退出 Peek", "Quit Peek"), action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    @MainActor @objc private func remoteSettings() { app?.showRemoteSettings() }
    @MainActor @objc private func toggleLaunchAtLogin() {
        let target = !SystemIntegration.launchAtLoginEnabled
        do {
            try SystemIntegration.setLaunchAtLogin(target)
        } catch {
            presentAlert(
                title: L10n.tr("无法更改登录项", "Cannot Update Login Item"),
                message: error.localizedDescription
            )
        }
    }
    @MainActor @objc private func installCLI() {
        do {
            let (link, inPath) = try SystemIntegration.installCLISymlink()
            if !inPath {
                presentAlert(
                    title: L10n.tr("已安装到 ~/bin/peek", "Installed to ~/bin/peek"),
                    message: L10n.tr(
                        "请将 ~/bin 加入 PATH：\nexport PATH=\"$HOME/bin:$PATH\"",
                        "Add ~/bin to your PATH:\nexport PATH=\"$HOME/bin:$PATH\""
                    )
                )
            } else {
                _ = link
            }
        } catch {
            presentAlert(
                title: L10n.tr("安装 peek 命令失败", "Failed to Install 'peek'"),
                message: error.localizedDescription
            )
        }
    }
    @MainActor private func presentAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    @objc private func openRow(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { app?.open(id, from: nil) }
    }
    @objc private func pickStyle(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let style = CardStyle(rawValue: raw) { app?.setStyle(style) }
    }
    @objc private func toggleDeck() { app?.setStacking(Prefs.stacking == .deck ? .list : .deck) }
    @objc private func revealRow(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { app?.reveal(id) }
    }
    @objc private func clearAll() { app?.clearAll() }
    @objc private func toggleTuck() { app?.toggleTuck() }
    @objc private func openNewest() { app?.openNewest() }
    @objc private func closeAll() { app?.dismissAll() }
    @objc private func quit() { NSApp.terminate(nil) }

    func snapshot() -> [String: Any] {
        let probe = NSMenu()
        menuNeedsUpdate(probe)
        let rows: [String] = probe.items.filter { !$0.isSeparatorItem && !$0.isAlternate }.map { item in
            if #available(macOS 14.4, *) {
                return "\(item.title) | \(item.subtitle ?? "")"
            } else {
                return "\(item.title) | \(item.toolTip ?? "")"
            }
        }
        return [
            "visible": status?.isVisible ?? false,
            "title": status?.button?.title ?? "",
            "rows": rows,
        ]
    }
}

private extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        let d = fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]])
        return NSFont(descriptor: d, size: pointSize) ?? self
    }
}
