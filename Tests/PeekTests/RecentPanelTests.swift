import AppKit
import Testing
@testable import Peek

@Suite(.serialized)
@MainActor
struct RecentPanelTests {
    @Test func shortcutBehaviorCanBeChangedFromTheMenu() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let key = "recentShortcutBehavior"
        let previous = defaults.object(forKey: key)
        defer { defaults.set(previous, forKey: key) }
        defaults.removeObject(forKey: key)
        #expect(Prefs.recentShortcutBehavior == .overview)
        defaults.set("unknown", forKey: key)
        #expect(Prefs.recentShortcutBehavior == .overview)

        let status = StatusMenu()
        let menu = NSMenu()
        func options() throws -> NSMenu {
            status.menuNeedsUpdate(menu)
            return try #require(menu.item(withTitle: L10n.tr("最近卡片快捷键", "Recent Cards Shortcut"))?.submenu)
        }
        for behavior in [RecentShortcutBehavior.singleUnread, .overview] {
            let submenu = try options()
            let index = submenu.indexOfItem(withTitle: behavior.label)
            try #require(index >= 0)
            #expect(submenu.item(at: index)?.state == .off)
            submenu.performActionForItem(at: index)
            #expect(defaults.string(forKey: key) == behavior.rawValue)
            let checked = try options().items.filter { $0.state == .on }
            #expect(checked.map(\.title) == [behavior.label])
        }
    }

    @Test func shortcutCountsUnreadCardsInTheOverview() {
        var recent = (0..<7).map { index in
            PeekItem(id: "card-\(index)", created: Date(), source: "Test", files: [], seen: true)
        }
        #expect(RecentPanel.singleUnread(in: []) == nil)
        #expect(RecentPanel.singleUnread(in: recent) == nil)
        recent[6].seen = false
        #expect(RecentPanel.singleUnread(in: recent) == nil)
        recent[5].seen = false
        recent[5].dismissed = true
        #expect(RecentPanel.singleUnread(in: recent)?.id == recent[5].id)
        recent[0].seen = false
        #expect(RecentPanel.singleUnread(in: recent) == nil)
    }

    @Test func opensFromTheSixMostRecentPushesIncludingDismissedCards() throws {
        _ = NSApplication.shared
        var opened: String?
        let panel = RecentPanel { id, _ in opened = id }
        defer { panel.close() }
        let history = (0..<8).map { index in
            PeekItem(id: "recent-\(index)", created: Date().addingTimeInterval(-Double(index)),
                     source: "Test", files: [], dismissed: true)
        }
        panel.present(history)
        for _ in history { try press(124, in: panel) }
        try press(36, in: panel)
        #expect(opened == history[5].id)
        #expect(panel.isVisible)
        panel.close()

        opened = nil
        panel.present(history)
        try press(124, in: panel)
        let incoming = PeekItem(id: "incoming", created: Date(), source: "Test", files: [])
        panel.update([incoming] + history)
        try press(36, in: panel)
        #expect(opened == history[1].id)

        opened = nil
        panel.present(history)
        panel.update([])
        try press(53, in: panel)
        #expect(opened == nil)
        #expect(!panel.isVisible)
    }

    @Test func closeShortcutsWorkThroughAppKitWithAndWithoutCards() throws {
        _ = NSApplication.shared
        let panel = RecentPanel { _, _ in Issue.record("Closing the overview opened a card") }
        defer { panel.close() }
        let item = PeekItem(id: "close-test", created: Date(), source: "Test", files: [])
        for history in [[], [item]] {
            panel.present(history)
            let heldEscape = try key(53, in: panel, text: "\u{1b}", repeatKey: true)
            #expect(panel.performKeyEquivalent(with: heldEscape))
            #expect(panel.isVisible)
            let commandW = try key(13, in: panel, text: "w", modifiers: .command)
            #expect(panel.performKeyEquivalent(with: commandW))
            #expect(!panel.isVisible)

            panel.present(history)
            panel.cancelOperation(nil)
            #expect(!panel.isVisible)
        }
    }

    @Test func escapeFromDetailReturnsToTheSameOverviewAndSelection() async throws {
        _ = NSApplication.shared
        let file = PeekFile(name: "note.txt", stored: "note.txt", original: "")
        let first = PeekItem(id: UUID().uuidString, created: Date(), source: "Test", files: [file])
        let second = PeekItem(id: UUID().uuidString, created: Date(), source: "Test", files: [file])
        let history = [first, second]
        defer { for item in history { Store.remove(item.id) } }
        for item in history {
            let url = try #require(item.urls.first)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("Preview".utf8).write(to: url)
        }
        let viewer = Viewer()
        var opened: [String] = []
        let panel = RecentPanel { id, source in
            opened.append(id)
            if let item = history.first(where: { $0.id == id }) {
                viewer.show(item, from: source.frame, returningTo: source)
            }
        }
        defer { panel.close() }
        panel.present(history)
        try press(124, in: panel)
        try press(36, in: panel)
        let detail = try #require(NSApp.windows.compactMap { $0 as? ViewerWindow }.first { $0.viewer === viewer })
        defer { detail.close() }
        #expect(detail.isVisible && panel.isVisible)
        detail.makeFirstResponder(detail)
        try press(53, in: detail)
        try await waitForPanelAnimation { !detail.isVisible }
        #expect(panel.isVisible)
        try press(36, in: panel)
        #expect(opened == [second.id, second.id])
        viewer.escape()
        try await waitForPanelAnimation { !detail.isVisible }
        try press(53, in: panel)
        #expect(!panel.isVisible)
    }

    private func press(_ code: UInt16, in window: NSWindow) throws {
        window.sendEvent(try key(code, in: window))
    }

    private func key(_ code: UInt16, in window: NSWindow, text: String = "",
                     modifiers: NSEvent.ModifierFlags = [], repeatKey: Bool = false) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: text, charactersIgnoringModifiers: text, isARepeat: repeatKey, keyCode: code))
    }
}
