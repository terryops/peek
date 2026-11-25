import AppKit
import Testing
@testable import Peek

@MainActor
struct FloatingCardTests {
    @Test func unopenedCardTucksEvenWhenHoveredAndItsHandleSurvivesRelayout() async throws {
        _ = NSApplication.shared
        let stack = CardStack()
        var item = PeekItem(id: UUID().uuidString, created: Date(), source: "Test", files: [])
        let id = item.id
        defer { stack.sync([]); Thumbs.forget(id) }
        _ = await withCheckedContinuation { continuation in
            Thumbs.load(item) { continuation.resume(returning: $0) }
        }
        stack.sync([item])
        stack.pointerEntered(force: true)
        #expect(stack.stackHovered)
        item.created = Date().addingTimeInterval(-301)
        stack.sync([item])
        #expect(stack.mode == .tucked)
        #expect(!stack.peeking)
        #expect(!stack.cards[0].shown)
        #expect(!stack.cards[0].model.item.seen)

        let number = try #require(stack.snapshot()["tabWindow"] as? Int)
        let handle = try #require(NSApp.window(withWindowNumber: number) as? CardPanel)
        let screen = try #require(handle.screen)
        #expect(handle.isVisible)
        #expect(handle.frame.size == EdgeTab.size)
        #expect(handle.frame.maxX == screen.visibleFrame.maxX)
        handle.orderOut(nil)
        stack.relayout()
        #expect(handle.isVisible)

        let button = try #require(handle.contentView?.subviews.compactMap { $0 as? ControlInteractionView }.first)
        #expect(button.accessibilityPerformPress())
        #expect(stack.mode == .normal)
        #expect(stack.cards[0].panel.isVisible)
        stack.tuck()
        stack.pointerEntered(force: true)
        #expect(stack.peeking)
        #expect(stack.cards[0].panel.isVisible)
    }

    @Test func backgroundViewerAllowsNewCardsOnTheRight() async throws {
        _ = NSApplication.shared
        let app = App()
        let viewer = Viewer()
        viewer.app = app
        viewer.takesKey = false

        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let file = PeekFile(name: "sample.tiff", stored: "sample.tiff", original: "")
        let first = PeekItem(id: UUID().uuidString, created: Date(), source: "Test", files: [file])
        let second = PeekItem(id: UUID().uuidString, created: Date(), source: "Test", files: [file])
        defer {
            app.cards.sync([])
            for item in [first, second] {
                Thumbs.forget(item.id)
                try? FileManager.default.removeItem(at: item.dir)
            }
        }
        let data = try #require(image.tiffRepresentation)
        for item in [first, second] {
            let url = try #require(item.urls.first)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            _ = await withCheckedContinuation { continuation in
                Thumbs.load(item) { continuation.resume(returning: $0) }
            }
        }

        app.cards.sync([first])
        let firstCard = try #require(app.cards.cards.first)
        viewer.show(first, from: firstCard.targetFrame)
        let window = try #require(NSApp.windows.compactMap { $0 as? ViewerWindow }.first { $0.viewer === viewer })
        defer { window.close() }
        #expect(firstCard.panel.isVisible)

        window.becomeKey()
        #expect(!firstCard.panel.isVisible)
        window.resignKey()
        #expect(window.isVisible)
        #expect(firstCard.panel.isVisible)

        app.cards.sync([second, first])
        let delivered = try #require(app.cards.cards.first)
        try await Task.sleep(for: .milliseconds(650))
        let screen = try #require(delivered.panel.screen)
        #expect(delivered.id == second.id)
        #expect(delivered.panel.isVisible)
        #expect(delivered.panel.alphaValue == 1)
        #expect(delivered.panel.frame.maxX == screen.visibleFrame.maxX - CardMetrics.edge)
        #expect(delivered.panel.frame.maxY == screen.visibleFrame.maxY - CardMetrics.top)
        #expect(!delivered.panel.isKeyWindow)
    }
}
