import AppKit
import SwiftUI

/// A keyboard-driven overview of recent pushes, including dismissed cards.
final class RecentPanel: NSPanel {
    static var displayTitle: String { L10n.tr("最近的 Peek", "Recent Peeks") }
    private static let limit = 6

    static func singleUnread(in history: [PeekItem]) -> PeekItem? {
        let unread = history.prefix(limit).filter { !$0.seen }
        return unread.count == 1 ? unread.first : nil
    }

    private let dismissAllCards: () -> Void
    private let openCard: (String, RecentPanel) -> Void
    private var previousApplication: NSRunningApplication?
    private var items: [PeekItem] = []
    private var selectedID: String?
    private var columns = 1
    private var host: NSHostingView<RecentGrid>?

    init(dismissAllCards: @escaping () -> Void, openCard: @escaping (String, RecentPanel) -> Void) {
        self.dismissAllCards = dismissAllCards
        self.openCard = openCard
        super.init(contentRect: .zero, styleMask: [.titled, .closable],
                   backing: .buffered, defer: false)
        title = Self.displayTitle
        isReleasedWhenClosed = false
        isFloatingPanel = false
        hidesOnDeactivate = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .canJoinAllApplications, .ignoresCycle]
        animationBehavior = .none
        tabbingMode = .disallowed
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func present(_ history: [PeekItem]) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != NSRunningApplication.current.processIdentifier {
            previousApplication = front
        }
        items = Array(history.prefix(Self.limit))
        if !isVisible || !items.contains(where: { $0.id == selectedID }) { selectedID = items.first?.id }
        layout(on: screen)
        makeFirstResponder(self)
        makeKeyAndOrderFront(nil)
        // An accessory app can order a window front without receiving keyboard focus.
        if !NSApp.isActive, Bundle.main.bundleURL.pathExtension == "app" {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            config.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { [weak self] _, error in
                if error != nil, self?.isVisible == true { NSApp.activate() }
            }
        } else {
            NSApp.activate()
        }
    }

    func update(_ history: [PeekItem]) {
        let recent = Array(history.prefix(Self.limit))
        guard recent != items else { return }
        let countChanged = recent.count != items.count
        items = recent
        if !recent.contains(where: { $0.id == selectedID }) { selectedID = recent.first?.id }
        if countChanged, let screen { layout(on: screen) } else { render() }
    }

    private func layout(on screen: NSScreen) {
        let area = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        columns = max(1, min(3, items.count, Int(area.width / 220)))
        let rows = (items.count + columns - 1) / columns
        let width = min(area.width, max(300, CGFloat(columns) * 230 + 24))
        let height = items.isEmpty ? 94 : RecentGrid.height(forRows: rows)
        var frame = frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: height))
        frame.size.height = min(frame.height, area.height)
        frame.origin = NSPoint(x: area.midX - frame.width / 2, y: area.midY - frame.height / 2)
        setFrame(frame.integral, display: false)
        render()
    }

    private func render() {
        let grid = RecentGrid(items: items, selectedID: selectedID, columns: columns) { [weak self] id in
            self?.choose(id)
        }
        if let host {
            host.rootView = grid
        } else {
            let host = NSHostingView(rootView: grid)
            host.sizingOptions = []
            contentView = host
            self.host = host
        }
    }

    private func choose(_ id: String) {
        if selectedID != id {
            selectedID = id
            render()
        }
        openCard(id, self)
    }

    override func close() {
        let returnTo = isKeyWindow && NSApp.isActive ? previousApplication : nil
        previousApplication = nil
        super.close()
        if let returnTo, !returnTo.isTerminated, NSApp.keyWindow == nil {
            NSApp.yieldActivation(to: returnTo)
            returnTo.activate(from: .current, options: [])
        }
    }

    private func handleCloseShortcut(_ event: NSEvent) -> Bool {
        guard isVisible, event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let isEscape = modifiers.isEmpty && event.keyCode == 53
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let isCommandW = modifiers == .command && (key == "w" || (key.isEmpty && event.keyCode == 13))
        guard isEscape || isCommandW else { return false }
        guard !event.isARepeat else { return true }
        close()
        if isCommandW { dismissAllCards() }
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let targetsOverview = event.window.map { $0 === self } ?? isKeyWindow
        return (targetsOverview && handleCloseShortcut(event)) || super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        guard isVisible, NSApp.keyWindow == nil || NSApp.keyWindow === self else { return }
        if let event = NSApp.currentEvent, event.type == .keyDown, event.isARepeat { return }
        close()
    }

    override func keyDown(with event: NSEvent) {
        if !handleCloseShortcut(event) { super.keyDown(with: event) }
    }

    override func sendEvent(_ event: NSEvent) {
        if handleCloseShortcut(event) { return }
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else {
            return super.sendEvent(event)
        }
        guard let index = items.firstIndex(where: { $0.id == selectedID }) else { return super.sendEvent(event) }
        let next: Int
        switch event.keyCode {
        case 36, 76:
            choose(items[index].id)
            return
        case 123: next = max(0, index - 1)
        case 124: next = min(items.count - 1, index + 1)
        case 126: next = index >= columns ? index - columns : index
        case 125: next = index / columns < (items.count - 1) / columns ? min(items.count - 1, index + columns) : index
        default: return super.sendEvent(event)
        }
        if next != index {
            selectedID = items[next].id
            render()
        }
    }
}

private struct RecentGrid: View {
    let items: [PeekItem]
    let selectedID: String?
    let columns: Int
    let open: (String) -> Void
    private static let tileHeight: CGFloat = 166
    private static let spacing: CGFloat = 8
    private static let padding: CGFloat = 12

    static func height(forRows rows: Int) -> CGFloat {
        CGFloat(rows) * tileHeight + CGFloat(rows - 1) * spacing + 2 * padding
    }

    var body: some View {
        if items.isEmpty {
            Text(L10n.tr("还没有最近的卡片", "No recent cards"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: columns),
                              spacing: Self.spacing) {
                        ForEach(items) { item in
                            RecentTile(item: item, selected: selectedID == item.id) { open(item.id) }
                                .frame(height: Self.tileHeight)
                        }
                    }
                    .padding(Self.padding)
                }
                .onChange(of: selectedID) { _, id in if let id { scroll.scrollTo(id) } }
            }
        }
    }
}

private struct RecentTile: View {
    let item: PeekItem
    let selected: Bool
    let open: () -> Void
    @State private var thumbs: [NSImage] = []
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 15)
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                PreviewPane(images: thumbs, count: item.files.count)
                    .accessibilityHidden(true)
                HStack(spacing: 5) {
                    Text(item.displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !item.seen {
                        Text(L10n.tr("未读", "Unread"))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.16), in: Capsule())
                            .fixedSize()
                    }
                }
                HStack {
                    Text(item.conversationTitle).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(item.created, style: .time).fixedSize()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(6)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .background(shape.fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(hovered ? 0.06 : 0)))
        .overlay(shape.strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2).allowsHitTesting(false))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hovered = $0 }
        .onAppear { Thumbs.load(item) { thumbs = $0 } }
    }
}
