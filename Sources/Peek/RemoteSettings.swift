import AppKit
import Combine

@MainActor final class RemoteSettings: NSWindowController, NSTextFieldDelegate {
    private let connections: RemoteConnections
    private let hostLabel = NSTextField(labelWithString: "")
    private let address = NSTextField(string: "")
    private let connectButton = NSButton(title: "", target: nil, action: nil)
    private let entryStatus = NSTextField(wrappingLabelWithString: "")
    private let rows = NSStackView()
    private var rowViews: [UUID: RemoteHostRow] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var entryError: String?

    init(connections: RemoteConnections) {
        self.connections = connections
        let window = RemoteSettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
                                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                          backing: .buffered, defer: false)
        window.title = L10n.tr("远程机器", "Remote Machines")
        window.minSize = NSSize(width: 620, height: 300)
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
        window?.title = L10n.tr("远程机器", "Remote Machines")
        refreshEntry()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if connections.hosts.isEmpty || address.stringValue.isEmpty { window?.makeFirstResponder(address) }
    }

    private func build(_ window: NSWindow) {
        guard let content = window.contentView else { return }
        hostLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        address.delegate = self
        address.target = self; address.action = #selector(submit)
        address.cell?.sendsActionOnEndEditing = false
        connectButton.target = self; connectButton.action = #selector(submit)
        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = "\r"
        let input = NSStackView(views: [address, connectButton])
        input.orientation = .horizontal; input.spacing = 10
        connectButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 88).isActive = true
        entryStatus.font = .systemFont(ofSize: 12)
        entryStatus.textColor = .systemRed
        entryStatus.isHidden = true
        let header = NSStackView(views: [hostLabel, input, entryStatus])
        header.orientation = .vertical; header.alignment = .leading; header.spacing = 8
        input.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        entryStatus.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
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
        entryError = nil
        refreshEntry()
    }

    @objc private func submit() {
        do {
            let input = address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try connections.add(address: input, label: input)
            address.stringValue = ""
            entryError = nil
        } catch {
            entryError = error.localizedDescription
        }
        refresh()
    }

    private func refreshEntry() {
        let fieldLabel = L10n.tr("SSH 主机", "SSH Host")
        hostLabel.stringValue = fieldLabel
        address.placeholderString = L10n.tr("user@host、user@host:端口 或 SSH 别名", "user@host, user@host:port, or SSH alias")
        address.setAccessibilityLabel(fieldLabel)
        entryStatus.setAccessibilityLabel(L10n.tr("连接状态", "Connection Status"))
        connectButton.title = L10n.tr("连接", "Connect")
        entryStatus.stringValue = entryError ?? ""
        entryStatus.isHidden = (entryError == nil)
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
            row.update(host: host, state: connections.states[host.id] ?? .disconnected, command: connections.senderCommand(for: host.id))
        }
        refreshEntry()
    }
}

@MainActor private final class RemoteHostRow: NSView {
    private var host: RemoteHost
    private let connections: RemoteConnections
    private let nameField = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(wrappingLabelWithString: "")
    private let commandField = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private let copyButton = NSButton(title: "", target: nil, action: nil)
    private let removeButton: NSButton
    private var command: String?
    private var copied = false

    init(host: RemoteHost, connections: RemoteConnections) {
        self.host = host; self.connections = connections
        removeButton = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: L10n.tr("移除连接", "Remove Connection"))!,
                                target: nil, action: nil)
        super.init(frame: .zero)
        nameField.font = .systemFont(ofSize: 13, weight: .semibold)
        nameField.lineBreakMode = .byTruncatingMiddle
        actionButton.target = self; actionButton.action = #selector(act)
        copyButton.target = self; copyButton.action = #selector(copyCommand)
        removeButton.target = self; removeButton.action = #selector(removeHost)
        for button in [actionButton, copyButton, removeButton] { button.bezelStyle = .rounded }
        actionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 88).isActive = true
        copyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        let top = NSStackView(views: [nameField, NSView(), actionButton, copyButton, removeButton])
        top.orientation = .horizontal; top.spacing = 8
        stateLabel.font = .systemFont(ofSize: 12)
        commandField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        commandField.textColor = .secondaryLabelColor
        commandField.isSelectable = true
        commandField.lineBreakMode = .byTruncatingMiddle
        let layout = NSStackView(views: [top, stateLabel, commandField])
        layout.orientation = .vertical; layout.alignment = .leading; layout.spacing = 4
        layout.translatesAutoresizingMaskIntoConstraints = false
        addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: leadingAnchor), layout.trailingAnchor.constraint(equalTo: trailingAnchor),
            layout.topAnchor.constraint(equalTo: topAnchor), layout.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            top.widthAnchor.constraint(equalTo: layout.widthAnchor), stateLabel.widthAnchor.constraint(equalTo: layout.widthAnchor),
            commandField.widthAnchor.constraint(equalTo: layout.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(host: RemoteHost, state: RemoteConnectionState, command: String?) {
        self.host = host
        if self.command != command { copied = false }
        self.command = command
        nameField.stringValue = host.label
        nameField.toolTip = host.address
        removeButton.toolTip = L10n.tr("移除连接，保留已接收文件", "Remove connection (downloaded files are kept)")
        actionButton.title = state.actionTitle
        stateLabel.stringValue = state.statusText
        stateLabel.textColor = state.isFailure ? .systemRed : .secondaryLabelColor
        commandField.stringValue = command ?? ""
        commandField.toolTip = command
        commandField.isHidden = (command == nil)
        copyButton.isEnabled = command != nil
        copyButton.title = copied ? L10n.tr("已拷贝", "Copied") : L10n.tr("拷贝命令", "Copy Command")
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
            copied = true; copyButton.title = L10n.tr("已拷贝", "Copied")
        }
    }
    @objc private func removeHost() { connections.remove(host.id) }
}

private extension RemoteConnectionState {
    var actionTitle: String {
        switch self {
        case .connecting, .installing, .reconnecting: return L10n.tr("取消", "Cancel")
        case .connected: return L10n.tr("断开连接", "Disconnect")
        case .disconnected: return L10n.tr("连接", "Connect")
        case .failed: return L10n.tr("重试", "Retry")
        }
    }
    var statusText: String {
        switch self {
        case .disconnected: return L10n.tr("已断开", "Disconnected")
        case .connecting: return L10n.tr("正在连接…", "Connecting…")
        case .installing: return L10n.tr("正在安装…", "Installing…")
        case .connected: return L10n.tr("已连接", "Connected")
        case .reconnecting: return L10n.tr("正在重新连接…", "Reconnecting…")
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
