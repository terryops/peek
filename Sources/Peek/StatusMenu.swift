import AppKit

/// Menu-bar history: everything from the last 24 hours, click to open again.
/// Remote management stays reachable even before the first card.
final class StatusMenu: NSObject, NSMenuDelegate {
    weak var app: App?
    private var status: NSStatusItem?
    private var items: [PeekItem] = []
    private let maxRows = 30

    func update(_ items: [PeekItem]) {
        self.items = items
        let s = status ?? make()
        s.isVisible = true
        let unread = items.filter { !$0.seen }.count
        guard let button = s.button else { return }
        button.title = unread > 0 ? "\(unread)" : ""
        button.imagePosition = unread > 0 ? .imageLeading : .imageOnly
        button.setAccessibilityLabel(unread > 0 ? "Peek，\(unread) 个未查看" : "Peek")
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
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        let placeholder = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)

        for item in items.prefix(maxRows) {
            var sub = "\(item.conversationTitle) · \(time.string(from: item.created))"
            if item.files.count > 1 { sub += " · \(item.files.count) 个文件" }
            let icon = Thumbs.cached(item)?.first.map { Thumbs.menuIcon($0) } ?? placeholder
            if Thumbs.cached(item) == nil { Thumbs.load(item) { _ in } }

            let row = NSMenuItem(title: item.displayTitle, action: #selector(openRow(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = item.id
            row.subtitle = sub
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
            alt.subtitle = "在访达中显示"
            alt.image = icon
            alt.isAlternate = true
            alt.keyEquivalentModifierMask = .option
            menu.addItem(alt)
        }

        if !items.isEmpty { menu.addItem(.separator()) }
        let remote = NSMenuItem(title: "远程机器…", action: #selector(remoteSettings), keyEquivalent: "")
        remote.target = self
        menu.addItem(remote)
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
        let deck = NSMenuItem(title: "叠放", action: #selector(toggleDeck), keyEquivalent: "")
        deck.target = self
        deck.state = Prefs.stacking == .deck ? .on : .off
        styles.addItem(deck)
        let styleRoot = NSMenuItem(title: "卡片样式", action: nil, keyEquivalent: "")
        styleRoot.submenu = styles
        menu.addItem(styleRoot)
        let newest = NSMenuItem(title: "打开最新一张", action: #selector(openNewest), keyEquivalent: "")
        newest.target = self
        Hotkeys.shared.decorate(newest, .open)
        menu.addItem(newest)
        if let stack = app?.cards, !stack.cards.isEmpty {
            let tucked = stack.mode == .tucked
            let toggle = NSMenuItem(title: tucked ? "显示卡片" : "暂时收起卡片", action: #selector(toggleTuck), keyEquivalent: "")
            toggle.target = self
            Hotkeys.shared.decorate(toggle, .tuck)
            menu.addItem(toggle)
            let closeAll = NSMenuItem(title: "全部关闭", action: #selector(closeAll), keyEquivalent: "")
            closeAll.target = self
            Hotkeys.shared.decorate(closeAll, .closeAll)
            menu.addItem(closeAll)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "全部清空", action: #selector(clearAll), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        let quit = NSMenuItem(title: "退出 Peek", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    @MainActor @objc private func remoteSettings() { app?.showRemoteSettings() }
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
        return [
            "visible": status?.isVisible ?? false,
            "title": status?.button?.title ?? "",
            "rows": probe.items.filter { !$0.isSeparatorItem && !$0.isAlternate }.map { "\($0.title) | \($0.subtitle ?? "")" },
        ]
    }
}

private extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        let d = fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]])
        return NSFont(descriptor: d, size: pointSize) ?? self
    }
}
