import AppKit
import AVKit
import Quartz
import SwiftUI
import Testing
import WebKit
@testable import Peek

@Suite(.serialized)
@MainActor
struct ViewerMediaTests {
    @Test func jumpControlsFollowTheCardOriginInAReusedViewer() async throws {
        try await withFixture(files: [.image("sample.png")]) { viewer, window, item in
            let terminal = PeekOrigin(terminalBundle: "com.apple.Terminal")
            let rex = PeekOrigin(rexSession: "session:123", rexBin: "/usr/bin/true")
            let help = try #require(window.contentView?.subviews.compactMap { $0 as? NSHostingView<ShortcutSheet> }.first)
            let label = L10n.tr("回到对话", "Jump to Session")
            var card = item
            let floating = Card(item: card, thumbs: [], style: .rich, stack: CardStack())
            let overlay = try #require(floating.panel.contentView?.subviews.compactMap { $0 as? CardInteractionView }.first)
            for (origin, enabled) in [(rex, true), (terminal, false), (rex, true)] {
                card.origin = origin
                floating.update(card)
                #expect((floating.contextMenu().item(withTitle: label) != nil) == enabled)
                #expect(overlay.accessibilityCustomActions()?.contains { $0.name == label } == enabled)
                viewer.show(card, from: nil)
                let toolbar = try #require(viewer.snapshot()["toolbar"] as? [String])
                #expect(toolbar.contains(label) == enabled)
                viewer.toggleHelp()
                #expect(help.rootView.m.canJump == enabled)
                viewer.toggleHelp()
                if !enabled {
                    try pressKey(36, in: window)
                    try await Task.sleep(for: .milliseconds(300))
                    #expect(viewer.isOpen)
                }
            }
            let jump = try #require(window.toolbar?.items.first { $0.label == label }?.view as? NSButton)
            jump.performClick(nil)
            try await waitUntil { !viewer.isOpen }
            #expect(!viewer.isOpen)
        }
    }

    @Test func shareButtonUsesTheDisplayedSnapshots() async throws {
        try await withFixture(files: [.image("first.png"), .image("second.png")]) { viewer, window, item in
            let share = try #require(window.toolbar?.items.compactMap { $0 as? NSSharingServicePickerToolbarItem }.first)
            let delegate = try #require(share.delegate)
            #expect(delegate.items(for: share) as? [URL] == [item.urls[0]])
            viewer.step(1)
            #expect(delegate.items(for: share) as? [URL] == [item.urls[1]])
            viewer.toggleCompare()
            #expect(delegate.items(for: share) as? [URL] == item.urls)
            viewer.toggleCompare()
            #expect(delegate.items(for: share) as? [URL] == [item.urls[1]])
        }
    }

    @Test func videoControlsAutoHideAndExposeFullScreenSupport() async throws {
        try await withFixture(files: [.video("clip.mp4", seconds: 6)]) { viewer, window, _ in
            #expect(window.collectionBehavior.contains(.fullScreenPrimary))
            let toolbar = try #require(viewer.snapshot()["toolbar"] as? [String])
            let fsLabel = L10n.tr("全屏  F", "Full Screen  F")
            #expect(toolbar.contains(fsLabel))

            let video = try #require(videoView(in: window) as? VideoPlayerView)
            #expect(video.showsFullScreenToggleButton)
            #expect(video.controlsStyle == .floating)

            video.autoHideDelay = 0.15
            video.mouseExitHideDelay = 0.08
            video.revealControls()
            #expect(video.controlsStyle == .floating)

            // Auto-hides when idle even while paused.
            try await waitUntil(timeout: 1) { video.controlsStyle == .none }
            #expect(video.controlsStyle == .none)

            // Moving the pointer over the video reveals the floating controls again.
            let center = video.convert(NSPoint(x: video.bounds.midX, y: video.bounds.midY), to: nil)
            let moved = try #require(NSEvent.mouseEvent(
                with: .mouseMoved, location: center, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0
            ))
            window.sendEvent(moved)
            #expect(video.controlsStyle == .floating)

            // Leaving the video hides the controls after the short exit delay.
            let exited = try #require(NSEvent.enterExitEvent(
                with: .mouseExited, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
            ))
            video.mouseExited(with: exited)
            try await waitUntil(timeout: 1) { video.controlsStyle == .none }
            #expect(video.controlsStyle == .none)

            // Entering AVKit video full screen keeps floating controls available and pauses custom auto-hide.
            video.playerViewWillEnterFullScreen(video)
            #expect(video.isInVideoFullScreen)
            #expect(video.controlsStyle == .floating)
            try await Task.sleep(for: .milliseconds(250))
            #expect(video.controlsStyle == .floating)

            // Exiting AVKit video full screen resumes auto-hide.
            video.playerViewDidExitFullScreen(video)
            #expect(!video.isInVideoFullScreen)
            #expect(video.controlsStyle == .floating)
            try await waitUntil(timeout: 1) { video.controlsStyle == .none }
            #expect(video.controlsStyle == .none)
        }
    }

    @Test func arrowsSeekAndAdjustVideoVolumeWithoutLeavingTheFile() async throws {
        try await withFixture(files: [.video("clip.mp4", seconds: 18), .image("still.png")]) { viewer, window, _ in
            let video = try #require(videoView(in: window))
            let player = try #require(video.player)
            try await waitUntil { player.currentItem?.status == .readyToPlay }
            window.makeFirstResponder(window)
            try pressKey(124, in: window)
            try #require(viewer.snapshot()["index"] as? Int == 0)
            try await waitUntil { abs(player.currentTime().seconds - 5) < 0.1 }
            #expect(abs(player.currentTime().seconds - 5) < 0.1)

            window.makeFirstResponder(video)
            try pressKey(124, in: window, repeating: true)
            try pressKey(124, in: window, repeating: true)
            try await waitUntil { abs(player.currentTime().seconds - 15) < 0.1 }
            #expect(abs(player.currentTime().seconds - 15) < 0.1)
            try pressKey(124, in: window)
            let duration = try #require(player.currentItem?.duration.seconds)
            try await waitUntil { abs(player.currentTime().seconds - duration) < 0.1 }
            #expect(abs(player.currentTime().seconds - duration) < 0.1)
            try pressKey(123, in: window)
            try await waitUntil { abs(player.currentTime().seconds - (duration - 5)) < 0.1 }
            #expect(abs(player.currentTime().seconds - (duration - 5)) < 0.1)
            #expect(player.rate == 0)

            try pressSpace(in: window)
            try pressKey(123, in: window)
            try await waitUntil { player.rate > 0 && player.currentTime().seconds < duration - 8 }
            #expect(player.rate > 0 && player.currentTime().seconds < duration - 8)
            try pressKey(125, in: window)
            #expect(abs(player.volume - 0.9) < 0.001)
            try pressKey(126, in: window)
            #expect(player.volume == 1)
            #expect(viewer.snapshot()["index"] as? Int == 0)

            try pressKey(124, in: window, modifiers: .shift)
            #expect(viewer.snapshot()["index"] as? Int == 1)
            try pressKey(123, in: window)
            #expect(viewer.snapshot()["index"] as? Int == 0)
        }
    }

    @Test func spacePlaysPausesAndResumesTheCurrentVideo() async throws {
        try await withFixture(files: [.video("clip.mp4"), .image("still.png")]) { viewer, window, _ in
            window.makeFirstResponder(window)
            try pressSpace(in: window)
            try await Task.sleep(for: .milliseconds(300))
            try #require(viewer.isOpen)
            let video = try #require(videoView(in: window))
            let player = try #require(video.player)
            try await waitUntil { player.currentTime().seconds > 0.1 }
            try #require(player.currentTime().seconds > 0.1)

            window.makeFirstResponder(video)
            try pressSpace(in: window)
            try #require(player.timeControlStatus == .paused)
            let pausedTime = player.currentTime().seconds
            try pressSpace(in: window, repeating: true)
            try await Task.sleep(for: .milliseconds(150))
            #expect(abs(player.currentTime().seconds - pausedTime) < 0.05)

            try pressSpace(in: window)
            try await waitUntil { player.currentTime().seconds > pausedTime + 0.1 }
            #expect(player.currentTime().seconds > pausedTime + 0.1)
            #expect(viewer.isOpen)

            viewer.step(1)
            #expect(player.rate == 0)
            try pressSpace(in: window)
            try await waitUntil { !viewer.isOpen }
            #expect(!viewer.isOpen)
        }
    }

    @Test func spaceReplaysFinishedVideoAndClosingStopsPlayback() async throws {
        try await withFixture(files: [.video("clip.mp4")]) { viewer, window, _ in
            let video = try #require(videoView(in: window))
            let player = try #require(video.player)
            try pressSpace(in: window)
            try await waitUntil(timeout: 5) { player.currentTime().seconds > 1 && player.rate == 0 }
            try #require(player.currentTime().seconds > 1 && player.rate == 0)
            try pressSpace(in: window)
            try await waitUntil { player.rate > 0 && (0.05..<1).contains(player.currentTime().seconds) }
            #expect(player.rate > 0 && (0.05..<1).contains(player.currentTime().seconds))
            let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            window.sendEvent(escape)
            #expect(player.rate == 0)
            try await waitUntil { !viewer.isOpen }
            #expect(!viewer.isOpen)
            #expect(video.player == nil)
        }
    }

    @Test func closingAudioViewerStopsQuickLookImmediatelyAndReleasesView() async throws {
        try await withFixture(files: [.audio("clip.wav")]) { viewer, window, item in
            let first: WeakRef<QLPreviewView>
            do {
                let ql = try #require(quickLookView(in: window))
                first = WeakRef(ql)
                #expect(!ql.shouldCloseWithWindow)
                #expect(ql.previewItem != nil)

                // Red close button asks delegate.windowShouldClose, which triggers viewer.close() and returns false.
                #expect(window.delegate?.windowShouldClose?(window) == false)
                // Playback must stop immediately rather than waiting for the close fade.
                #expect(ql.previewItem == nil)
                try await waitUntil { !viewer.isOpen }
            }
            #expect(window.contentView?.subviews.contains { $0 is ViewerDocumentPage } == false)
            try await waitUntil { first.value == nil }
            #expect(first.value == nil)

            // Reopening the same card creates a fresh QLPreviewView and closes cleanly again.
            viewer.show(item, from: nil)
            window.orderBack(nil)
            try await Task.sleep(for: .milliseconds(400))
            let second: WeakRef<QLPreviewView>
            do {
                let ql2 = try #require(quickLookView(in: window))
                second = WeakRef(ql2)
                #expect(ql2.previewItem != nil)
                viewer.close()
                #expect(ql2.previewItem == nil)
                try await waitUntil { !viewer.isOpen }
            }
            try await waitUntil { second.value == nil }
            #expect(second.value == nil)
        }
    }

    @Test func reopeningDuringCloseAnimationDisposesPreviousQuickLookView() async throws {
        try await withFixture(files: [.audio("clip.wav")]) { viewer, window, item in
            let first: WeakRef<QLPreviewView>
            do {
                let ql = try #require(quickLookView(in: window))
                first = WeakRef(ql)
                #expect(window.delegate?.windowShouldClose?(window) == false)
                #expect(ql.previewItem == nil)
            }

            // Immediately reopen before the 0.16s close animation completes.
            viewer.show(item, from: nil)
            window.orderBack(nil)
            try await Task.sleep(for: .milliseconds(300))

            #expect(viewer.isOpen)
            let secondQL = try #require(quickLookView(in: window))
            #expect(secondQL !== first.value)
            #expect(secondQL.previewItem != nil)
            try await waitUntil { first.value == nil }
            #expect(first.value == nil)
        }
    }

    @Test func steppingAndSwipingAwayFromAudioClosesQuickLook() async throws {
        try await withFixture(files: [.audio("0.wav"), .image("1.png")]) { viewer, window, _ in
            let stepped: WeakRef<QLPreviewView>
            do {
                let ql = try #require(quickLookView(in: window))
                stepped = WeakRef(ql)
                #expect(ql.previewItem != nil)
                viewer.step(1)
                #expect(ql.previewItem == nil)
            }
            try await waitUntil { stepped.value == nil }
            #expect(stepped.value == nil)

            viewer.step(-1)
            let swiped: WeakRef<QLPreviewView>
            do {
                let ql = try #require(quickLookView(in: window))
                swiped = WeakRef(ql)
                #expect(ql.previewItem != nil)
                viewer.finishSwipe(1)
            }
            try await waitUntil { swiped.value == nil }
            #expect(swiped.value == nil)
        }
    }

    @Test func cancelledVerticalSwipePreviewClosesQuickLook() async throws {
        try await withFixture(files: [.image("0.png"), .audio("1.wav")]) { viewer, window, _ in
            guard !Anim.reduceMotion else { return }
            let preview: WeakRef<QLPreviewView>
            do {
                viewer.updateSwipe(120, orientation: .vertical)
                let ql = try #require(quickLookView(in: window))
                preview = WeakRef(ql)
                #expect(ql.previewItem != nil)
                viewer.releaseSwipe(120, orientation: .vertical, cancelled: true)
            }
            try await waitUntil { preview.value == nil }
            #expect(preview.value == nil)
        }
    }

    @Test func closingPlayingHTMLVideoStopsMediaAndReleasesWebView() async throws {
        try await withFixture(files: [.htmlVideo("player.html", videoName: "clip.mp4")]) { viewer, window, _ in
            let webRef: WeakRef<WebDocView>
            do {
                let web = try #require(webView(in: window))
                webRef = WeakRef(web)
                try await waitUntil(timeout: 5) {
                    await web.mediaPlaybackState() == .playing
                }
                #expect(await web.mediaPlaybackState() == .playing)

                #expect(window.delegate?.windowShouldClose?(window) == false)
                try await waitUntil { !viewer.isOpen }
            }
            #expect(window.contentView?.subviews.contains { $0 is ViewerDocumentPage } == false)
            try await waitUntil { webRef.value == nil }
            #expect(webRef.value == nil)
        }
    }

    @Test func removingItemClosesViewerAndReleasesQuickLook() async throws {
        try await withFixture(files: [.audio("clip.wav")]) { viewer, window, _ in
            let qlRef: WeakRef<QLPreviewView>
            do {
                let ql = try #require(quickLookView(in: window))
                qlRef = WeakRef(ql)
                #expect(ql.previewItem != nil)
                viewer.itemsChanged([])
                #expect(ql.previewItem == nil)
                try await waitUntil { !viewer.isOpen }
            }
            try await waitUntil { qlRef.value == nil }
            #expect(qlRef.value == nil)
        }
    }

    // MARK: fixtures

    private final class WeakRef<T: AnyObject> {
        weak var value: T?
        init(_ value: T) { self.value = value }
    }

    private enum FixtureFile {
        case video(String, seconds: Int = 2)
        case audio(String)
        case image(String)
        case htmlVideo(String, videoName: String)

        var fileName: String {
            switch self {
            case .video(let name, _), .audio(let name), .image(let name), .htmlVideo(let name, _): name
            }
        }
    }

    private func withFixture(files: [FixtureFile],
                             _ body: (Viewer, ViewerWindow, PeekItem) async throws -> Void) async throws {
        _ = NSApplication.shared
        let item = PeekItem(
            id: "media-test-\(UUID().uuidString)",
            created: Date(),
            source: "Test",
            files: files.map { PeekFile(name: $0.fileName, stored: $0.fileName, original: "") }
        )
        let folder = item.dir.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: item.dir) }

        for file in files {
            switch file {
            case .video(let name, let seconds):
                try await writeMP4(to: folder.appendingPathComponent(name), seconds: seconds)
            case .audio(let name):
                let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
                buffer.frameLength = 8_000
                try AVAudioFile(forWriting: folder.appendingPathComponent(name), settings: format.settings)
                    .write(from: buffer)
            case .image(let name):
                try writePNG(to: folder.appendingPathComponent(name))
            case .htmlVideo(let name, let videoName):
                try await writeMP4(to: folder.appendingPathComponent(videoName))
                let html = """
                <!doctype html>
                <html><body>
                <video id="v" src="\(videoName)" autoplay loop muted playsinline width="160" height="120"></video>
                </body></html>
                """
                try Data(html.utf8).write(to: folder.appendingPathComponent(name))
            }
        }

        let viewer = Viewer()
        viewer.takesKey = false
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let origin = NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY, width: 1, height: 1)
        viewer.show(item, from: origin)
        let window = try #require(NSApp.windows.compactMap { $0 as? ViewerWindow }.first { $0.viewer === viewer })
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(450))
        window.setFrame(NSRect(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.minY + 20,
                               width: 900, height: 640), display: false)
        window.contentView?.layoutSubtreeIfNeeded()
        defer {
            window.delegate = nil
            window.close()
        }
        try await body(viewer, window, item)
    }

    private func quickLookView(in window: ViewerWindow) -> QLPreviewView? {
        window.contentView?.subviews.lazy.compactMap { ($0 as? ViewerDocumentPage)?.document as? QLPreviewView }.first
    }

    private func videoView(in window: ViewerWindow) -> AVPlayerView? {
        window.contentView?.subviews.lazy.compactMap { ($0 as? ViewerDocumentPage)?.document as? AVPlayerView }.first
    }

    private func pressSpace(in window: ViewerWindow, repeating: Bool = false) throws {
        try pressKey(49, in: window, repeating: repeating)
    }

    private func pressKey(_ code: UInt16, in window: ViewerWindow, repeating: Bool = false,
                          modifiers: NSEvent.ModifierFlags = []) throws {
        let chars = code == 49 ? " " : ""
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: repeating, keyCode: code))
        window.sendEvent(event)
    }

    private func webView(in window: ViewerWindow) -> WebDocView? {
        window.contentView?.subviews.lazy.compactMap { ($0 as? ViewerDocumentPage)?.document as? WebDocView }.first
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func writePNG(to url: URL) throws {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 200,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    private func writeMP4(to url: URL, seconds: Int = 2) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160,
            AVVideoHeightKey: 120,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 160,
                kCVPixelBufferHeightKey as String: 120,
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 15) {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 160, 120, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pb = try #require(buffer)
            adaptor.append(pb, withPresentationTime: CMTime(value: Int64(frame), timescale: 15))
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        #expect(writer.status == .completed)
    }
}

private extension WKWebView {
    @MainActor
    func mediaPlaybackState() async -> WKMediaPlaybackState {
        await withCheckedContinuation { continuation in
            requestMediaPlaybackState { state in
                continuation.resume(returning: state)
            }
        }
    }
}
