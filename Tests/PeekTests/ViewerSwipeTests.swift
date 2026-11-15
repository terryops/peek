import AppKit
import SwiftUI
import Testing
@testable import Peek

@Suite(.serialized)
@MainActor
struct ViewerSwipeTests {
    @Test func externalDisplayOpensImagesSideBySide() async throws {
        for screen in NSScreen.screens {
            let displayID = try #require(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
            guard CGDisplayIsBuiltin(displayID) == 0 else { continue }
            try await withViewer(allowComparison: true, on: screen) { viewer, window in
                #expect(viewer.snapshot()["compare"] as? Bool == true)
                #expect(window.contentView?.subviews.contains { $0 is ZoomImageView } == false)
                viewer.toggleCompare()
                #expect(viewer.snapshot()["compare"] as? Bool == false)
                viewer.step(1)
                #expect(viewer.snapshot()["index"] as? Int == 1)
            }
        }
    }

    @Test func singleImagesAndDocumentsStaySingleOnExternalDisplay() async throws {
        try await withViewer(fileCount: 1, allowComparison: true) { viewer, _ in
            #expect(viewer.snapshot()["compare"] as? Bool == false)
        }
        try await withViewer(document: true, allowComparison: true) { viewer, _ in
            #expect(viewer.snapshot()["compare"] as? Bool == false)
        }
    }

    @Test func comparisonIncludesImagesAfterTheFourth() async throws {
        try await withViewer(fileCount: 5) { viewer, window in
            for _ in 0..<50 {
                let strip = window.contentView?.subviews.compactMap { $0 as? NSHostingView<FilmstripView> }.first
                if strip?.rootView.m.thumbs.count == 5 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let strip = try #require(window.contentView?.subviews.compactMap { $0 as? NSHostingView<FilmstripView> }.first)
            #expect(strip.rootView.m.thumbs.count == 5)
            viewer.toggleCompare()
            let comparison = try #require(window.contentView?.subviews.compactMap { $0 as? NSHostingView<CompareView> }.first)
            #expect(comparison.rootView.images.count == 5)
            #expect(comparison.rootView.names.count == 5)
            viewer.zoom(.zoomIn)
            #expect(comparison.rootView.zoom.scale > 1)
            viewer.zoom(.fit)
            #expect(comparison.rootView.zoom.scale == 1)
        }
    }

    @Test func mouseWheelMovesBetweenImagesAndWraps() async throws {
        try await withViewer { viewer, window in
            scroll(window, x: 0, y: 1, phase: [], precise: false, timestamp: 100)
            #expect(viewer.snapshot()["index"] as? Int == 1)
            scroll(window, x: 0, y: -1, phase: [], precise: false, timestamp: 100.01)
            #expect(viewer.snapshot()["index"] as? Int == 0)
            scroll(window, x: 0, y: -1, phase: [], precise: false, timestamp: 100.3)
            #expect(viewer.snapshot()["index"] as? Int == 2)
        }
    }

    @Test func wheelBurstDoesNotSkipImages() async throws {
        try await withViewer { viewer, window in
            for time in [10.0, 10.02, 10.08] {
                scroll(window, x: 0, y: 3, phase: [], precise: false, timestamp: time)
            }
            #expect(viewer.snapshot()["index"] as? Int == 1)
            scroll(window, x: 0, y: 3, phase: [], precise: false, timestamp: 10.3)
            #expect(viewer.snapshot()["index"] as? Int == 2)
        }
    }

    @Test func highResolutionMouseWheelChangesImagesWithoutGesturePhases() async throws {
        try await withViewer { viewer, window in
            scroll(window, x: 0, y: 30, phase: [], precise: true)
            #expect(viewer.snapshot()["index"] as? Int == 1)
        }
    }

    @Test func wheelPreservesDocumentAndZoomedImageScrolling() async throws {
        try await withViewer(document: true) { viewer, window in
            scroll(window, x: 0, y: 3, phase: [], precise: false)
            #expect(viewer.snapshot()["index"] as? Int == 0)
        }
        try await withViewer { viewer, window in
            let image = try #require(window.contentView?.subviews.compactMap { $0 as? ZoomImageView }.first)
            image.magnification = 4
            image.layoutSubtreeIfNeeded()
            scroll(window, x: 0, y: 3, phase: [], precise: false)
            #expect(viewer.snapshot()["index"] as? Int == 0)
            image.magnification = 0.5
            image.layoutSubtreeIfNeeded()
            scroll(window, x: 0, y: 3, phase: [], precise: false)
            #expect(viewer.snapshot()["index"] as? Int == 1)
        }
    }

    @Test func wheelDoesNotNavigateComparisonHelpOrSingleFiles() async throws {
        try await withViewer { viewer, window in
            viewer.toggleCompare()
            scroll(window, x: 0, y: 3, phase: [], precise: false)
            #expect(viewer.snapshot()["compare"] as? Bool == true)
            #expect(viewer.snapshot()["index"] as? Int == 0)
            viewer.toggleCompare()
            viewer.toggleHelp()
            scroll(window, x: 0, y: 3, phase: [], precise: false)
            #expect(viewer.snapshot()["index"] as? Int == 0)
        }
        try await withViewer(fileCount: 1) { viewer, window in
            scroll(window, x: 0, y: 3, phase: [], precise: false)
            #expect(viewer.snapshot()["index"] as? Int == 0)
        }
    }

    @Test func verticallyEnlargedImageKeepsWheelScrolling() async throws {
        try await withViewer { viewer, window in
            let image = try #require(window.contentView?.subviews.compactMap { $0 as? ZoomImageView }.first)
            let document = try #require(image.documentView)
            // Fit the width while overflowing vertically on both 1x and 2x screens.
            let horizontalFit = image.contentView.bounds.width * image.magnification / document.bounds.width
            let verticalFit = (image.contentView.bounds.height * image.magnification
                - image.contentInsets.top - image.contentInsets.bottom) / document.bounds.height
            image.magnification = (horizontalFit + verticalFit) / 2
            image.layoutSubtreeIfNeeded()
            #expect(viewer.acceptsSwipeNavigation)
            #expect(!viewer.acceptsWheelNavigation)
            scroll(window, x: 0, y: 3, phase: [], precise: false)
            #expect(viewer.snapshot()["index"] as? Int == 0)
        }
    }

    @Test func releaseKeepsOutgoingContentAttachedUntilAnimationCompletes() async throws {
        try await withViewer { viewer, window in
            let original = try #require(window.contentView)
            let outgoing = try #require(original.subviews.compactMap { $0 as? ZoomImageView }.first)
            let recording = RemovalRecordingView(frame: original.bounds)
            let children = original.subviews.map { ($0, $0.frame) }
            window.contentView = recording
            for (child, frame) in children {
                child.translatesAutoresizingMaskIntoConstraints = true
                recording.addSubview(child)
                child.frame = frame
            }
            recording.removed.removeAll()
            swipe(window, x: -100)
            #expect(viewer.snapshot()["index"] as? Int == 1)
            if !Anim.reduceMotion {
                #expect(!recording.removed.contains { $0 === outgoing })
            }
            try await Task.sleep(for: .milliseconds(400))
            #expect(recording.removed.contains { $0 === outgoing })
        }
    }

    @Test func restingFingersDoNotCancelReleaseAnimation() async throws {
        try await withViewer { _, window in
            swipe(window, x: -100)
            let incoming = try #require(window.contentView?.subviews.compactMap { $0 as? ZoomImageView }.first)
            scroll(window, x: 0, phase: .mayBegin)
            if !Anim.reduceMotion { #expect(incoming.layer?.animation(forKey: "viewerSwipe") != nil) }
        }
    }

    @Test func contentFollowsDragWithoutChangingSelection() async throws {
        try await withViewer { viewer, window in
            let image = try #require(window.contentView?.subviews.compactMap { $0 as? ZoomImageView }.first)
            scroll(window, x: 0, phase: .began)
            scroll(window, x: -35, phase: .changed)
            let left = image.layer?.transform.m41 ?? 0
            #expect(Anim.reduceMotion ? left == 0 : left < -20)
            #expect(viewer.snapshot()["index"] as? Int == 0)
            scroll(window, x: 70, phase: .changed)
            let right = image.layer?.transform.m41 ?? 0
            #expect(Anim.reduceMotion ? right == 0 : right > 20)
            scroll(window, x: 0, phase: .cancelled)
        }
    }

    @Test func shortDragAnimatesBackToRest() async throws {
        try await withViewer { viewer, window in
            let image = try #require(window.contentView?.subviews.compactMap { $0 as? ZoomImageView }.first)
            swipe(window, x: -35)
            #expect(image.layer?.transform.m41 ?? 0 == 0)
            if !Anim.reduceMotion { #expect(image.layer?.animation(forKey: "viewerSwipe") != nil) }
            #expect(viewer.snapshot()["index"] as? Int == 0)
        }
    }

    @Test func completedSwipeAnimatesBothPagesThenRemovesOutgoingView() async throws {
        try await withViewer { viewer, window in
            let outgoing = try #require(window.contentView?.subviews.compactMap { $0 as? ZoomImageView }.first)
            swipe(window, x: -100)
            #expect(viewer.snapshot()["index"] as? Int == 1)
            if !Anim.reduceMotion {
                #expect(outgoing.superview === window.contentView)
                #expect(outgoing.layer?.animation(forKey: "viewerSwipe") != nil)
                let incoming = try #require(window.contentView?.subviews.compactMap { $0 as? ZoomImageView }.first { $0 !== outgoing })
                #expect(incoming.layer?.animation(forKey: "viewerSwipe") != nil)
            }
            try await Task.sleep(for: .milliseconds(400))
            #expect(outgoing.superview == nil)
            #expect(window.contentView?.subviews.compactMap { $0 as? ZoomImageView }.count == 1)
        }
    }

    @Test func newGestureCancelsPreviousTransitionWithoutLeavingViews() async throws {
        try await withViewer { viewer, window in
            swipe(window, x: -100)
            scroll(window, x: 0, phase: .began)
            #expect(window.contentView?.subviews.compactMap { $0 as? ZoomImageView }.count == 1)
            scroll(window, x: 100, phase: .changed)
            scroll(window, x: 0, phase: .ended)
            try await Task.sleep(for: .milliseconds(400))
            #expect(viewer.snapshot()["index"] as? Int == 0)
            #expect(window.contentView?.subviews.compactMap { $0 as? ZoomImageView }.count == 1)
        }
    }

    @Test func clickingDuringDragCancelsTheGesture() async throws {
        try await withViewer { viewer, window in
            scroll(window, x: 0, phase: .began)
            scroll(window, x: -100, phase: .changed)
            let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
                                                       modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil,
                                                       eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(click)
            scroll(window, x: 0, phase: .ended)
            #expect(viewer.snapshot()["index"] as? Int == 0)
            let image = try #require(window.contentView?.subviews.compactMap { $0 as? ZoomImageView }.first)
            #expect(image.layer?.transform.m41 ?? 0 == 0)
        }
    }

    @Test func leftAndRightSwipeChangeFiles() async throws {
        try await withViewer { viewer, window in
            swipe(window, x: -100)
            #expect(viewer.snapshot()["index"] as? Int == 1)
            swipe(window, x: 100)
            #expect(viewer.snapshot()["index"] as? Int == 0)
            swipe(window, x: 100)
            #expect(viewer.snapshot()["index"] as? Int == 2)
        }
    }

    @Test func longSwipeAndMomentumOnlyChangeOneFile() async throws {
        try await withViewer { viewer, window in
            scroll(window, x: 0, phase: .began)
            for _ in 0..<8 { scroll(window, x: -40, phase: .changed) }
            scroll(window, x: 0, phase: .ended)
            scroll(window, x: -200, phase: [], momentum: .began)
            scroll(window, x: -200, phase: [], momentum: .changed)
            scroll(window, x: 0, phase: [], momentum: .ended)
            #expect(viewer.snapshot()["index"] as? Int == 1)
        }
    }

    @Test func shortVerticalAndCancelledSwipesDoNotChangeFiles() async throws {
        try await withViewer { viewer, window in
            swipe(window, x: -15)
            swipe(window, x: -100, y: 200)
            scroll(window, x: 0, phase: .began)
            scroll(window, x: -100, phase: .changed)
            scroll(window, x: 0, phase: .cancelled)
            #expect(viewer.snapshot()["index"] as? Int == 0)
        }
    }

    @Test func verticalGestureStaysScrollingEvenIfItTurnsHorizontal() async throws {
        try await withViewer { viewer, window in
            scroll(window, x: 0, phase: .began)
            scroll(window, x: -2, y: 40, phase: .changed)
            scroll(window, x: -200, phase: .changed)
            scroll(window, x: 0, phase: .ended)
            #expect(viewer.snapshot()["index"] as? Int == 0)
        }
    }

    @Test func horizontalMouseWheelDoesNotChangeFiles() async throws {
        try await withViewer { viewer, window in
            swipe(window, x: -100, precise: false)
            #expect(viewer.snapshot()["index"] as? Int == 0)
        }
    }

    @Test func mayBeginAndMovementInBeganAreHandled() async throws {
        try await withViewer { viewer, window in
            scroll(window, x: 0, phase: .mayBegin)
            scroll(window, x: -30, phase: .began)
            scroll(window, x: -40, phase: .changed)
            scroll(window, x: 0, phase: .ended)
            #expect(viewer.snapshot()["index"] as? Int == 1)
        }
    }

    @Test func incompleteGestureDoesNotNavigate() async throws {
        try await withViewer { viewer, window in
            scroll(window, x: -100, phase: .changed)
            scroll(window, x: 0, phase: .ended)
            #expect(viewer.snapshot()["index"] as? Int == 0)
        }
    }

    @Test func singleFileDoesNotNavigate() async throws {
        try await withViewer(fileCount: 1) { viewer, window in
            swipe(window, x: -100)
            #expect(viewer.snapshot()["index"] as? Int == 0)
        }
    }

    @Test func documentsNavigateHorizontallyAndKeepVerticalScrolling() async throws {
        try await withViewer(document: true) { viewer, window in
            swipe(window, x: -100)
            #expect(viewer.snapshot()["index"] as? Int == 1)
            try await waitForDocument(window)
            swipe(window, x: 0, y: 200)
            #expect(viewer.snapshot()["index"] as? Int == 1)
            swipe(window, x: 100)
            #expect(viewer.snapshot()["index"] as? Int == 0)
            try await waitForDocument(window)
        }
    }

    @Test func horizontallyScrollableDocumentKeepsScrolling() async throws {
        try await withViewer(document: true, overflow: true) { viewer, window in
            swipe(window, x: -100)
            #expect(viewer.snapshot()["index"] as? Int == 0)
        }
    }

    @Test func pinchZoomedDocumentKeepsPanning() async throws {
        try await withViewer(document: true) { viewer, window in
            let web = try #require(window.contentView?.subviews.compactMap { $0 as? WebDocView }.first)
            web.magnification = 2
            swipe(window, x: -100)
            #expect(viewer.snapshot()["index"] as? Int == 0)
        }
    }

    @Test func comparisonAndHelpDoNotNavigate() async throws {
        try await withViewer { viewer, window in
            viewer.toggleCompare()
            swipe(window, x: -100)
            #expect(viewer.snapshot()["index"] as? Int == 0)
            viewer.toggleCompare()
            viewer.toggleHelp()
            swipe(window, x: -100)
            #expect(viewer.snapshot()["index"] as? Int == 0)
            viewer.toggleHelp()
            swipe(window, x: -100)
            #expect(viewer.snapshot()["index"] as? Int == 1)
        }
    }

    @Test func zoomedImageKeepsHorizontalPanning() async throws {
        try await withViewer { viewer, window in
            let image = try #require(window.contentView?.subviews.compactMap { $0 as? ZoomImageView }.first)
            image.magnification = 4
            image.layoutSubtreeIfNeeded()
            swipe(window, x: -100)
            #expect(viewer.snapshot()["index"] as? Int == 0)
            image.magnification = 0.5
            image.layoutSubtreeIfNeeded()
            swipe(window, x: -100)
            #expect(viewer.snapshot()["index"] as? Int == 1)
        }
    }

    private func withViewer(fileCount: Int = 3, document: Bool = false, overflow: Bool = false,
                            allowComparison: Bool = false, on targetScreen: NSScreen? = nil,
                            _ body: (Viewer, ViewerWindow) async throws -> Void) async throws {
        _ = NSApplication.shared
        let ext = document ? "md" : "png"
        let item = PeekItem(id: "swipe-test-\(UUID().uuidString)", created: Date(), source: "Test",
                            files: (0..<fileCount).map { PeekFile(name: "\($0).\(ext)", stored: "\($0).\(ext)", original: "") })
        let folder = item.dir.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: item.dir) }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 1000,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                                  bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let text = overflow ? "```\n\(String(repeating: "long_line_", count: 100))\n```" : "# Test\n\nDocument"
        for url in item.urls { try (document ? Data(text.utf8) : png).write(to: url) }
        let viewer = Viewer()
        viewer.takesKey = false
        let screen = try #require(targetScreen ?? NSScreen.main)
        let origin = NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY, width: 1, height: 1)
        viewer.show(item, from: origin)
        if !allowComparison, viewer.snapshot()["compare"] as? Bool == true { viewer.toggleCompare() }
        let window = try #require(NSApp.windows.compactMap { $0 as? ViewerWindow }.first { $0.viewer === viewer })
        // AppKit's layer-backed scroll monitor needs a real screen. Keep the window
        // behind the user's apps rather than moving it offscreen (screen == nil).
        window.setFrame(NSRect(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.minY + 20,
                               width: 900, height: 640), display: false)
        window.orderBack(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        defer { window.delegate = nil; window.close() }
        if document { try await waitForDocument(window) }
        try await body(viewer, window)
    }

    private func waitForDocument(_ window: ViewerWindow) async throws {
        let web = try #require(window.contentView?.subviews.compactMap { $0 as? WebDocView }.first)
        let deadline = Date().addingTimeInterval(5)
        while web.hasHorizontalOverflow == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(web.hasHorizontalOverflow != nil)
    }

    private func swipe(_ window: ViewerWindow, x: Int32, y: Int32 = 0, precise: Bool = true) {
        scroll(window, x: 0, phase: .began, precise: precise)
        scroll(window, x: x, y: y, phase: .changed, precise: precise)
        scroll(window, x: 0, phase: .ended, precise: precise)
    }

    private func scroll(_ window: ViewerWindow, x: Int32, y: Int32 = 0, phase: NSEvent.Phase,
                        momentum: NSEvent.Phase = [], precise: Bool = true, timestamp: TimeInterval? = nil) {
        // Non-natural scrolling: a finger moving left produces positive deltas.
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
                         wheelCount: 2, wheel1: -y, wheel2: -x, wheel3: 0)!
        // These events exercise the window's navigation/animation handler directly.
        // Keep pass-through events outside children: NSScrollView otherwise enters
        // native concurrent tracking, which waits for events in the system queue.
        cg.location = CGPoint(x: -10000, y: -10000)
        if let timestamp { cg.timestamp = UInt64(timestamp * 1_000_000_000) }
        // CoreGraphics and AppKit use different raw values for both phase enums.
        let cgPhase: CGScrollPhase?
        switch phase {
        case .began: cgPhase = .began
        case .changed: cgPhase = .changed
        case .ended: cgPhase = .ended
        case .cancelled: cgPhase = .cancelled
        case .mayBegin: cgPhase = .mayBegin
        default: cgPhase = nil
        }
        let cgMomentum: CGMomentumScrollPhase
        switch momentum {
        case .began: cgMomentum = .begin
        case .changed: cgMomentum = .continuous
        case .ended: cgMomentum = .end
        default: cgMomentum = .none
        }
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(cgPhase?.rawValue ?? 0))
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(cgMomentum.rawValue))
        let event = NSEvent(cgEvent: cg)!
        precondition(event.phase == phase && event.momentumPhase == momentum)
        window.sendEvent(event)
    }
}

@MainActor
private final class RemovalRecordingView: NSView {
    var removed: [NSView] = []

    override func willRemoveSubview(_ subview: NSView) {
        removed.append(subview)
        super.willRemoveSubview(subview)
    }
}
