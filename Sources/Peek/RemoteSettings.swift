import AppKit
import Combine

@MainActor final class RemoteSettings: NSWindowController, NSTextFieldDelegate {
    private let connections: RemoteConnections
    private let address = NSTextField(string: "")
    private let connectButton = NSButton(title: "连接", target: nil, action: nil)
    private let entryStatus = NSTextField(wrappingLabelWithString: "")
    private let rows = NSStackView()
    private var rowViews: [UUID: RemoteHostRow] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var submittedID: UUID?
    private var submittedAddress: String?
    private var entryError: String?

    init(connections: RemoteConnections) {
        self.connections = connections
        let window = RemoteSettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 440),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "远程机器"
        window.minSize = NSSize(width: 620, height: 330)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
        build(window)
        Publishers.CombineLatest3(connections.$hosts, connections.$states, connections.$commands)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.refresh() }
            .store(in: &subscriptions)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if connections.hosts.isEmpty { window?.makeFirstResponder(address) }
    }
    private func build(_ window: NSWindow) {
        guard let content = window.contentView else { return }
        let label = NSTextField(labelWithString: "SSH 主机")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        address.placeholderString = "user@host 或 SSH 别名"
        address.setAccessibilityLabel("SSH 主机")
        address.delegate = self
        address.target = self; address.action = #selector(submit)
        address.cell?.sendsActionOnEndEditing = false
        connectButton.target = self; connectButton.action = #selector(submit)
        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = "\r"
        let input = NSStackView(views: [address, connectButton])
        input.orientation = .horizontal; input.spacing = 10
        connectButton.widthAnchor.constraint(equalToConstant: 88).isActive = true
        entryStatus.font = .systemFont(ofSize: 12)
        entryStatus.textColor = .secondaryLabelColor
        entryStatus.setAccessibilityLabel("连接状态")
        let header = NSStackView(views: [label, input, entryStatus])
        header.orientation = .vertical; header.alignment = .leading; header.spacing = 8
        input.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        entryStatus.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        entryStatus.heightAnchor.constraint(equalToConstant: 34).isActive = true
        let divider = NSBox(); divider.boxType = .separator
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 12
        rows.translatesAutoresizingMaskIntoConstraints = false
        let document = NSView(); document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows); scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rows.topAnchor.constraint(equalTo: document.topAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        let layout = NSStackView(views: [header, divider, scroll])
        layout.orientation = .vertical; layout.alignment = .leading; layout.spacing = 14
        layout.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            layout.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            layout.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            layout.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            header.widthAnchor.constraint(equalTo: layout.widthAnchor),
            divider.widthAnchor.constraint(equalTo: layout.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: layout.widthAnchor),
        ])
    }
    func controlTextDidChange(_ notification: Notification) {
        if address.stringValue != submittedAddress { submittedID = nil; entryError = nil }
        refreshEntry()
    }
    @objc private func submit() {
        if let id = submittedID, connections.hosts.contains(where: { $0.id == id }) {
            switch connections.states[id] ?? .disconnected {
            case .connecting, .installing, .reconnecting: connections.disconnect(id)
            case .connected: connections.disconnect(id)
            case .disconnected, .failed: connections.connect(id)
            }
        } else {
            do {
                let input = address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                submittedID = try connections.add(address: input, label: input)
                submittedAddress = address.stringValue
                entryError = nil
            } catch { entryError = error.localizedDescription }
        }
        refresh()
    }
    private func refreshEntry() {
        if let id = submittedID, connections.hosts.contains(where: { $0.id == id }) {
            let state = connections.states[id] ?? .disconnected
            connectButton.title = state.actionTitle
            // The persisted host's status lives in its row. Keep this space
            // reserved for input validation without moving the primary action.
            entryStatus.stringValue = ""
            entryStatus.textColor = .secondaryLabelColor
        } else {
            connectButton.title = "连接"
            entryStatus.stringValue = entryError ?? ""
            entryStatus.textColor = .systemRed
        }
    }
    private func refresh() {
        let live = Set(connections.hosts.map(\.id))
        for id in Array(rowViews.keys) where !live.contains(id) {
            if let row = rowViews.removeValue(forKey: id) { rows.removeArrangedSubview(row); row.removeFromSuperview() }
        }
        for host in connections.hosts {
            let row: RemoteHostRow
            if let existing = rowViews[host.id] { row = existing }
            else {
                row = RemoteHostRow(host: host, connections: connections)
                rowViews[host.id] = row; rows.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            }
            row.update(connections.states[host.id] ?? .disconnected, command: connections.senderCommand(for: host.id))
        }
        refreshEntry()
    }
}

@MainActor private final class RemoteHostRow: NSView {
    private let host: RemoteHost
    private let connections: RemoteConnections
    private let stateLabel = NSTextField(wrappingLabelWithString: "")
    private let commandField = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "连接", target: nil, action: nil)
    private let copyButton = NSButton(title: "拷贝命令", target: nil, action: nil)
    private var command: String?
    private var copied = false

    init(host: RemoteHost, connections: RemoteConnections) {
        self.host = host; self.connections = connections
        super.init(frame: .zero)
        let name = NSTextField(labelWithString: host.label)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingMiddle
        name.toolTip = host.address
        actionButton.target = self; actionButton.action = #selector(act)
        copyButton.target = self; copyButton.action = #selector(copyCommand)
        let remove = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "移除连接")!, target: self, action: #selector(removeHost))
        remove.toolTip = "移除连接，保留已接收文件"
        for button in [actionButton, copyButton, remove] { button.bezelStyle = .rounded }
        actionButton.widthAnchor.constraint(equalToConstant: 82).isActive = true
        copyButton.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let top = NSStackView(views: [name, NSView(), actionButton, copyButton, remove])
        top.orientation = .horizontal; top.spacing = 8
        stateLabel.font = .systemFont(ofSize: 12)
        commandField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        commandField.textColor = .secondaryLabelColor
        commandField.isSelectable = true
        commandField.lineBreakMode = .byTruncatingMiddle
        let layout = NSStackView(views: [top, stateLabel, commandField])
        layout.orientation = .vertical; layout.alignment = .leading; layout.spacing = 5
        layout.translatesAutoresizingMaskIntoConstraints = false
        addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: leadingAnchor), layout.trailingAnchor.constraint(equalTo: trailingAnchor),
            layout.topAnchor.constraint(equalTo: topAnchor), layout.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            top.widthAnchor.constraint(equalTo: layout.widthAnchor), stateLabel.widthAnchor.constraint(equalTo: layout.widthAnchor),
            commandField.widthAnchor.constraint(equalTo: layout.widthAnchor),
            stateLabel.heightAnchor.constraint(equalToConstant: 32), commandField.heightAnchor.constraint(equalToConstant: 16),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ state: RemoteConnectionState, command: String?) {
        if self.command != command { copied = false }
        self.command = command
        actionButton.title = state.actionTitle
        stateLabel.stringValue = state.statusText
        stateLabel.textColor = state.isFailure ? .systemRed : .secondaryLabelColor
        commandField.stringValue = command ?? ""
        commandField.toolTip = command
        copyButton.isEnabled = command != nil
        copyButton.title = copied ? "已拷贝" : "拷贝命令"
    }
    @objc private func act() {
        switch connections.states[host.id] ?? .disconnected {
        case .connected, .connecting, .installing, .reconnecting: connections.disconnect(host.id)
        case .disconnected, .failed: connections.connect(host.id)
        }
    }
    @objc private func copyCommand() {
        guard let command else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(command, forType: .string) {
            copied = true; copyButton.title = "已拷贝"
        }
    }
    @objc private func removeHost() { connections.remove(host.id) }
}

private extension RemoteConnectionState {
    var actionTitle: String {
        switch self {
        case .connecting, .installing, .reconnecting: return "取消"
        case .connected: return "断开连接"
        case .disconnected: return "连接"
        case .failed: return "重试"
        }
    }
    var statusText: String {
        switch self {
        case .disconnected: return "已断开"
        case .connecting: return "正在连接…"
        case .installing: return "正在安装…"
        case .connected: return "已连接"
        case .reconnecting: return "正在重新连接…"
        case .failed(let error): return error.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    var isFailure: Bool { if case .failed = self { return true }; return false }
}

/// Background apps have no standard Edit menu. Keep editing equivalents scoped
/// to this window's field editor so the viewer retains its own Command keys.
private final class RemoteSettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           let editor = firstResponder as? NSTextView, editor.isFieldEditor {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": editor.selectAll(nil)
            case "c": editor.copy(nil)
            case "v": editor.paste(nil)
            case "x": editor.cut(nil)
            default: return super.performKeyEquivalent(with: event)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
