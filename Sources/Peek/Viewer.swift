import AppKit
import AVKit
import PDFKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers

enum SwipeOrientation {
    case horizontal, vertical

    func direction(for offset: CGFloat) -> Int {
        let towardNext = self == .horizontal ? offset < 0 : offset > 0
        return towardNext ? 1 : -1
    }
}

/// Peek's own viewer. Peek is an accessory app, so this never adds a Dock icon,
/// and closing it hands focus back to whatever you were using before.
final class Viewer: NSObject, NSWindowDelegate, NSToolbarDelegate, NSSharingServicePickerToolbarItemDelegate {
    static let shared = Viewer()
    weak var app: App?

    private var window: ViewerWindow?
    private var previousApplication: NSRunningApplication?
    private weak var sourceWindow: NSWindow?
    private var closeAnimation: UUID?
    private var closeAfterExitingFullScreen = false
    private var item: PeekItem?
    private var index = 0
    private var compare = false
    private var main: NSView?
    private var displayedContent: NSView? { (main as? ViewerDocumentPage)?.document ?? main }
    private let strip = StripModel()
    private var stripHost: NSHostingView<FilmstripView>?
    private let help = HelpModel()
    private var helpHost: NSView?
    private var feedback: ViewerFeedbackView?
    private var feedbackTimer: Timer?
    private let compareZoom = CompareZoomModel()
    private var swipeOffset: CGFloat = 0
    private var swipePreview: (index: Int, view: NSView)?
    private var swipeOutgoing: NSView?
    private var swipeAnimationGeneration = 0
    fileprivate static let swipeDuration: TimeInterval = 0.26
    private static let sidebarWidth: CGFloat = 172
    private static let sidebarBreakpoint: CGFloat = 760

    var isOpen: Bool { window?.isVisible ?? false }
    /// Debug only: open without taking the keyboard.
    var takesKey = true
    /// Test hook to observe full-screen toggles without animating the system Space.
    var fullScreenHandler: (() -> Void)?
    func isShowing(_ id: String) -> Bool { isOpen && item?.id == id }

    func snapshot() -> [String: Any] {
        guard let win = window, win.isVisible else { return ["open": false] }
        return [
            "open": true,
            "window": win.windowNumber,
            "frame": NSStringFromRect(win.frame),
            "title": win.title,
            "subtitle": win.subtitle,
            "index": index,
            "compare": compare,
            "navigation": showStrip ? (strip.sidebar ? "sidebar" : "filmstrip") : "none",
            "file": item?.files[index].name ?? "",
            "help": help.visible,
            "item": item?.displayTitle ?? "",
            "key": win.isKeyWindow,
            "appActive": NSApp.isActive,
            "content": displayedContent.map { String(describing: type(of: $0)) } ?? "-",
            "magnification": (main as? ZoomImageView)?.magnification ?? 0,
            "swipeOffset": swipeOffset,
            "fullScreen": win.styleMask.contains(.fullScreen),
            "toolbar": win.toolbar?.items.filter { isToolbarItemVisible($0) }.map(\.label) ?? [],
        ]
    }

    // MARK: open / close

    func show(_ item: PeekItem, from origin: NSRect?, returningTo sourceWindow: NSWindow? = nil) {
        guard !item.files.isEmpty else { return }
        self.sourceWindow = sourceWindow
        if takesKey, let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != NSRunningApplication.current.processIdentifier {
            previousApplication = front
        }
        let wasClosing = closeAnimation != nil
        closeAnimation = nil
        closeAfterExitingFullScreen = false
        let reopenSame = isOpen && self.item?.id == item.id
        self.item = item
        let screen = origin.flatMap { r in NSScreen.screens.first { $0.frame.intersects(r) } } ?? NSScreen.main ?? NSScreen.screens[0]
        index = 0
        compare = false

        let win = window ?? makeWindow()
        win.resetSwipe()
        dismissFeedback()
        let target = idealFrame(on: screen)
        reloadContent()
        if win.isMiniaturized { win.deminiaturize(nil) }

        let alreadyVisible = win.isVisible
        if !alreadyVisible {
            let start = origin ?? target.insetBy(dx: target.width * 0.06, dy: target.height * 0.06)
            win.setFrame(start, display: false)
            win.alphaValue = 0
        }
        if takesKey {
            // WindowServer routes trackpad magnify gestures to the active application.
            NSApp.activate()
            win.makeKeyAndOrderFront(nil)
        } else {
            win.orderFrontRegardless()
        }
        if (!alreadyVisible || !reopenSame || wasClosing) && !win.styleMask.contains(.fullScreen) {
            let duration = alreadyVisible ? 0.32 : (Anim.reduceMotion ? 0.15 : 0.34)
            Anim.run(duration, alreadyVisible ? Anim.outQuint : Anim.outExpo) {
                win.animator().setFrame(target, display: true)
                win.animator().alphaValue = 1
            }
        } else if win.alphaValue < 1 {
            win.alphaValue = 1
        }
        syncToolbar(win.toolbar)
    }

    func close() {
        guard let win = window, closeAnimation == nil else { return }
        guard win.isVisible || win.isMiniaturized else {
            clearContent()
            return
        }
        win.resetSwipe()
        dismissFeedback()
        if win.styleMask.contains(.fullScreen) {
            (main as? ViewerDocumentPage)?.stopMedia()
            closeAfterExitingFullScreen = true
            win.toggleFullScreen(nil)
            return
        }
        if win.isMiniaturized {
            if let id = item?.id { app?.cards.retractAfterPreview(id) }
            clearContent()
            previousApplication = nil
            win.orderOut(nil)
            return
        }
        (main as? ViewerDocumentPage)?.stopMedia()
        let animation = UUID()
        closeAnimation = animation
        let f = win.frame
        Anim.run(0.16, Anim.inCubic, {
            win.animator().alphaValue = 0
            win.animator().setFrame(f.insetBy(dx: f.width * 0.03, dy: f.height * 0.03), display: true)
        }, done: { [weak self] in
            guard let self, self.closeAnimation == animation else { return }
            self.closeAnimation = nil
            let hadFocus = win.isKeyWindow && NSApp.isActive
            let sourceWindow = hadFocus ? self.sourceWindow : nil
            let returnTo = hadFocus ? self.previousApplication : nil
            self.previousApplication = nil
            if let id = self.item?.id { self.app?.cards.retractAfterPreview(id) }
            win.orderOut(nil)
            win.alphaValue = 1
            self.clearContent()
            if let sourceWindow, sourceWindow.isVisible, !sourceWindow.isMiniaturized {
                sourceWindow.makeKeyAndOrderFront(nil)
            } else if let returnTo, !returnTo.isTerminated, NSApp.keyWindow == nil {
                NSApp.yieldActivation(to: returnTo)
                returnTo.activate(from: .current, options: [])
            }
        })
    }

    func clearContent() {
        sourceWindow = nil
        app?.cards.setViewerFocused(false, viewedCardID: item?.id)
        closeAnimation = nil
        cancelSwipeAnimation()
        dispose(main)
        main = nil
        item = nil
        strip.thumbs = []
        strip.names = []
        strip.visible = false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        clearContent()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        app?.cards.setViewerFocused(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        app?.cards.setViewerFocused(false, viewedCardID: item?.id)
    }

    /// Item changed on disk (deleted / cleaned up): close if it's gone.
    func itemsChanged(_ items: [PeekItem]) {
        guard let current = item, isOpen || window?.isMiniaturized == true else { return }
        if let fresh = items.first(where: { $0.id == current.id }) {
            item = fresh
        } else {
            close()
        }
    }

    // MARK: window

    private func makeWindow() -> ViewerWindow {
        let win = ViewerWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable],
                               backing: .buffered, defer: false)
        win.isFloatingPanel = false
        win.hidesOnDeactivate = false
        win.becomesKeyOnlyIfNeeded = false
        win.viewer = self
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .visible
        win.toolbarStyle = .unified
        win.appearance = NSAppearance(named: .darkAqua)
        win.backgroundColor = NSColor(white: 0.075, alpha: 1)
        win.isMovableByWindowBackground = true
        win.minSize = NSSize(width: 460, height: 340)
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
        win.animationBehavior = .none
        win.tabbingMode = .disallowed

        let toolbar = NSToolbar(identifier: "PeekViewer")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        win.toolbar = toolbar

        let container = ViewerContentView()
        container.onResize = { [weak self] in self?.layoutContent() }
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        win.contentView = container

        let host = NSHostingView(rootView: FilmstripView(m: strip) { [weak self] i in self?.select(i) })
        host.sizingOptions = []
        container.addSubview(host)
        stripHost = host

        let helpView = NSHostingView(rootView: ShortcutSheet(m: help))
        helpView.sizingOptions = []
        helpView.frame = container.bounds
        helpView.autoresizingMask = [.width, .height]
        helpView.isHidden = true
        container.addSubview(helpView)
        helpHost = helpView

        window = win
        return win
    }

    /// Centers a content-sized detail window within the usable area of its display.
    private func idealFrame(on screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        let scale = screen.backingScaleFactor
        let preferredScale: CGFloat = 1.07
        let maxW = vf.width * 0.86, maxH = vf.height * 0.94
        let sidebar = showStrip && maxW >= Self.sidebarBreakpoint
        let chrome: CGFloat = 52 + (showStrip && !sidebar ? 84 : 0)
        var size = NSSize(width: vf.width * 0.60, height: vf.height * 0.70)
        if let item, !compare, WebDoc.isWeb(item.urls[index]) || item.urls[index].pathExtension.lowercased() == "pdf" {
            let w: CGFloat = WebDoc.isMarkdown(item.urls[index]) ? 920 : 1240
            size = NSSize(width: w, height: vf.height * 0.86)
        } else if let item, !compare, let px = pixelSize(item.urls[index]) {
            size = NSSize(width: px.width / scale + (sidebar ? Self.sidebarWidth : 0), height: px.height / scale + chrome)
        } else if let item, compare {
            let sizes = item.urls.compactMap(pixelSize)
            let h = sizes.map(\.height).max() ?? 1000
            let w = sizes.reduce(0) { $0 + $1.width * (h / max($1.height, 1)) }
            size = NSSize(width: w / scale + CGFloat(sizes.count + 1) * 16, height: h / scale + chrome)
        }
        let k = min(preferredScale, maxW / size.width, maxH / size.height)
        let w = min(maxW, max((sidebar ? 800 : 560) * preferredScale, size.width * k))
        let h = min(maxH, max((sidebar ? 520 : 400) * preferredScale, size.height * k))
        return NSRect(x: vf.midX - w / 2, y: vf.midY - h / 2, width: w, height: h).integral
    }

    private func pixelSize(_ url: URL) -> NSSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              var w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              var h = props[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        if let o = props[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
        return NSSize(width: w, height: h)
    }

    private var showStrip: Bool { (item?.files.count ?? 0) > 1 && !compare }

    func windowDidResize(_ notification: Notification) {
        layoutContent()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        layoutContent()
        syncToolbar(window?.toolbar)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        layoutContent()
        syncToolbar(window?.toolbar)
        if closeAfterExitingFullScreen {
            closeAfterExitingFullScreen = false
            close()
        }
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        if closeAfterExitingFullScreen {
            closeAfterExitingFullScreen = false
            clearContent()
            window.orderOut(nil)
        }
    }

    /// Give scrolling content its own viewport between the toolbar and navigation.
    private func layoutContent() {
        guard let win = window, let container = win.contentView else { return }
        let bounds = container.bounds
        let sidebar = showStrip && bounds.width >= Self.sidebarBreakpoint
        if strip.sidebar != sidebar { strip.sidebar = sidebar }
        stripHost?.isHidden = !showStrip
        let left = sidebar ? Self.sidebarWidth : 0
        let bottom: CGFloat = showStrip && !sidebar ? 84 : 0
        let contentHeight = min(bounds.height, win.contentLayoutRect.height)
        stripHost?.frame = sidebar
            ? NSRect(x: 0, y: 0, width: left, height: contentHeight)
            : NSRect(x: 0, y: 0, width: bounds.width, height: bottom)
        let viewport = NSRect(x: left, y: bottom, width: max(0, bounds.width - left),
                              height: max(0, contentHeight - bottom))
        for view in [main, swipePreview?.view, swipeOutgoing].compactMap({ $0 }) {
            view.frame = viewport
        }
        if let feedback {
            let origin = feedback.rootView.progress == nil
                ? NSPoint(x: bounds.maxX - feedback.frame.width - 16, y: contentHeight - feedback.frame.height - 12)
                : NSPoint(x: viewport.midX - feedback.frame.width / 2, y: viewport.minY + 20)
            feedback.setFrameOrigin(origin)
        }
    }

    func isOverNavigation(_ event: NSEvent) -> Bool {
        guard showStrip, let host = stripHost, let container = window?.contentView else { return false }
        return host.frame.contains(container.convert(event.locationInWindow, from: nil))
    }

    var hasThumbnailSidebar: Bool { showStrip && strip.sidebar && !help.visible }

    // MARK: content

    private func reloadContent(preserving outgoing: NSView? = nil, incomingOffset: CGFloat = 0,
                               orientation: SwipeOrientation = .horizontal, prepared: NSView? = nil) {
        guard let item, let win = window, let container = win.contentView else { return }
        win.cancelSwipeTracking()
        if outgoing == nil {
            cancelSwipeAnimation()
            dispose(main)
            main = nil
        } else {
            // The displayed backing store must stay attached throughout the handoff.
            swipeAnimationGeneration += 1
            swipeOffset = 0
        }
        index = min(index, max(0, item.files.count - 1))

        let view: NSView
        if let prepared {
            view = prepared
        } else if compare {
            compareZoom.reset()
            let images = item.urls.map { NSImage(contentsOf: $0) ?? NSWorkspace.shared.icon(forFile: $0.path) }
            let host = NSHostingView(rootView: CompareView(images: images, names: item.files.map(\.name), zoom: compareZoom,
                                                         pick: { [weak self] i in self?.select(i) }))
            host.sizingOptions = []
            view = host
        } else {
            view = Self.makeViewer(for: item.urls[index])
        }
        if outgoing != nil { positionSwipeView(view, at: incomingOffset, orientation: orientation) }
        if view.superview !== container {
            container.addSubview(view, positioned: .below, relativeTo: outgoing ?? stripHost)
        }
        if help.visible { toggleHelp() }
        main = view
        layoutContent()

        let cachedThumbs = Thumbs.cached(item) ?? []
        strip.thumbs = cachedThumbs
        strip.names = item.files.map(\.name)
        strip.selected = index
        strip.visible = showStrip
        if showStrip, cachedThumbs.count < item.urls.count {
            let wantedID = item.id
            Thumbs.load(item, limit: item.urls.count) { [weak self] imgs in
                guard let self, self.item?.id == wantedID else { return }
                self.strip.thumbs = imgs
            }
        }
        win.title = showStrip ? item.files[index].name : item.displayTitle
        var sub = item.conversationTitle
        if item.files.count > 1 && !compare { sub += " · \(index + 1)/\(item.files.count)" }
        sub += " · " + RelativeTime.string(item.created, now: Date())
        win.subtitle = sub
        syncToolbar(win.toolbar)
    }

    private static func makeViewer(for url: URL) -> NSView {
        if WebDoc.isWeb(url) { return ViewerDocumentPage(WebDocView(url: url)) }
        let ext = url.pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext), type.conforms(to: .movie),
           let mime = type.preferredMIMEType, AVURLAsset.isPlayableExtendedMIMEType(mime) {
            let video = VideoPlayerView()
            video.player = AVPlayer(url: url)
            return ViewerDocumentPage(video)
        }
        if ext == "pdf", let doc = PDFDocument(url: url) {
            let v = PDFView()
            v.document = doc
            v.autoScales = true
            v.displayMode = .singlePageContinuous
            v.backgroundColor = NSColor(white: 0.075, alpha: 1)
            return ViewerDocumentPage(v)
        }
        if let img = NSImage(contentsOf: url), img.isValid {
            let v = ZoomImageView()
            v.setImage(img)
            return v
        }
        guard let ql = QLPreviewView(frame: .zero, style: .normal) else { return NSView() }
        // Viewer owns closing QLPreviewView explicitly; letting AppKit close it too can double-close.
        ql.shouldCloseWithWindow = false
        ql.previewItem = url as NSURL
        return ViewerDocumentPage(ql)
    }

    private func dispose(_ view: NSView?) {
        (view as? ViewerDocumentPage)?.teardown()
        view?.removeFromSuperview()
    }

    private func select(_ i: Int) {
        guard let item, i >= 0, i < item.files.count, i != index || compare else { return }
        index = i
        compare = false
        reloadContent()
    }

    func step(_ d: Int) {
        guard let item, item.files.count > 1 else { return }
        select((index + d + item.files.count) % item.files.count)
    }

    // MARK: interactive swipe animation

    func cancelSwipeAnimation() {
        dismissWrapFeedback()
        swipeAnimationGeneration += 1
        dispose(swipePreview?.view)
        swipePreview = nil
        dispose(swipeOutgoing)
        swipeOutgoing = nil
        swipeOffset = 0
        if let main, main.layer != nil {
            main.layer?.removeAnimation(forKey: "viewerSwipe")
            positionSwipeView(main, at: 0)
        }
    }

    func updateSwipe(_ offset: CGFloat, orientation: SwipeOrientation = .horizontal) {
        guard let main, orientation == .horizontal ? acceptsSwipeNavigation : hasThumbnailSidebar else { return }
        updateWrapFeedback(direction: orientation.direction(for: offset), distance: abs(offset))
        guard !Anim.reduceMotion else { return }
        switch orientation {
        case .horizontal:
            let limit = max(1, main.bounds.width * 0.4)
            swipeOffset = limit * CGFloat(tanh(Double(offset / limit)))
        case .vertical:
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            let distance = verticalSwipeDistance
            swipeOffset = min(distance, max(-distance, offset))
            if swipeOffset == 0 {
                dispose(swipePreview?.view)
                swipePreview = nil
            } else {
                let direction = swipeOffset > 0 ? 1 : -1
                previewVerticalNeighbor(direction, at: swipeOffset - CGFloat(direction) * distance)
            }
            positionSwipeView(main, at: swipeOffset, orientation: .vertical)
            return
        }
        positionSwipeView(main, at: swipeOffset, orientation: orientation)
    }

    private var verticalSwipeDistance: CGFloat {
        guard let window, let content = window.contentView else { return 1 }
        return max(1, min(content.bounds.height, window.contentLayoutRect.height))
    }

    private func previewVerticalNeighbor(_ direction: Int, at offset: CGFloat) {
        guard let item, let main, let container = main.superview else { return }
        let neighbor = (index + direction + item.files.count) % item.files.count
        if let preview = swipePreview, preview.index == neighbor {
            positionSwipeView(preview.view, at: offset, orientation: .vertical)
            return
        }
        dispose(swipePreview?.view)
        let view = Self.makeViewer(for: item.urls[neighbor])
        swipePreview = (neighbor, view)
        container.addSubview(view, positioned: .below, relativeTo: main)
        layoutContent()
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        positionSwipeView(view, at: offset, orientation: .vertical)
    }

    private func wraps(_ direction: Int) -> Bool {
        guard let item, item.files.count > 1 else { return false }
        return direction > 0 ? index == item.files.count - 1 : index == 0
    }

    fileprivate func pageThreshold(_ direction: Int) -> CGFloat {
        wraps(direction) ? 192 : 96
    }

    func releaseSwipe(_ offset: CGFloat, orientation: SwipeOrientation = .horizontal, cancelled: Bool = false) {
        let direction = orientation.direction(for: offset)
        let reachedThreshold = abs(offset) >= pageThreshold(direction)
        if cancelled {
            dismissWrapFeedback()
        } else if !reachedThreshold, var hint = feedback?.rootView, hint.progress != nil {
            // Let a short flick's hint remain readable while the page springs back.
            hint.progress = 0
            showFeedback(hint, timeout: 0.9)
        }
        finishSwipe(!cancelled && reachedThreshold ? direction : nil, orientation: orientation)
    }

    /// Continue from the dragged position, keeping the two visible pages attached at release.
    func finishSwipe(_ direction: Int?, orientation: SwipeOrientation = .horizontal) {
        guard let outgoing = main else { return }
        let offset = swipeOffset
        let preview = swipePreview
        swipePreview = nil
        swipeOffset = 0
        let canNavigate = orientation == .horizontal ? acceptsSwipeNavigation : hasThumbnailSidebar
        guard let direction, canNavigate else {
            if !canNavigate { dismissWrapFeedback() }
            guard offset != 0 else {
                dispose(preview?.view)
                return
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let preview {
                let edge = offset > 0 ? -verticalSwipeDistance : verticalSwipeDistance
                removeSwipeViewAfterAnimation(preview.view)
                animateSwipeView(preview.view, from: offset + edge, to: edge, orientation: orientation)
            }
            animateSwipeView(outgoing, from: offset, to: 0, orientation: orientation)
            CATransaction.commit()
            return
        }
        let didWrap = wraps(direction)
        defer {
            if didWrap {
                let message = direction > 0 ? L10n.tr("已回到第一张", "Back at the first item")
                                            : L10n.tr("已到最后一张", "At the last item")
                showFeedback(ViewerFeedback(message: message, symbol: "checkmark", progress: 1), timeout: 1)
            }
        }
        guard !Anim.reduceMotion, let container = outgoing.superview else {
            dispose(preview?.view)
            step(direction)
            return
        }

        guard let item else { return }
        let destination = orientation == .horizontal
            ? outgoing.bounds.width * CGFloat(-direction)
            : verticalSwipeDistance * CGFloat(direction)
        // Prepare both views and their animations in one render transaction.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        index = (index + direction + item.files.count) % item.files.count
        let prepared = preview?.index == index ? preview?.view : nil
        if prepared == nil { dispose(preview?.view) }
        reloadContent(preserving: outgoing, incomingOffset: offset - destination, orientation: orientation, prepared: prepared)
        guard let incoming = main, incoming !== outgoing else { return }
        container.layoutSubtreeIfNeeded()
        incoming.displayIfNeeded()

        (outgoing as? ViewerDocumentPage)?.pausePlayback()
        removeSwipeViewAfterAnimation(outgoing)
        animateSwipeView(outgoing, from: offset, to: destination, orientation: orientation)
        animateSwipeView(incoming, from: offset - destination, to: 0, orientation: orientation)
    }

    private func removeSwipeViewAfterAnimation(_ view: NSView) {
        if swipeOutgoing !== view { dispose(swipeOutgoing) }
        swipeOutgoing = view
        let generation = swipeAnimationGeneration
        let remove = { [weak self] in
            guard let self, self.swipeAnimationGeneration == generation else { return }
            self.dispose(self.swipeOutgoing)
            self.swipeOutgoing = nil
        }
        CATransaction.setCompletionBlock(remove)
        // Non-visible window backing stores can defer the transaction completion.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.swipeDuration + 0.08, execute: remove)
    }

    private func positionSwipeView(_ view: NSView, at offset: CGFloat, orientation: SwipeOrientation = .horizontal) {
        view.wantsLayer = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let translation = orientation == .horizontal
            ? CATransform3DMakeTranslation(offset, 0, 0)
            : CATransform3DMakeTranslation(0, offset, 0)
        if view is ViewerDocumentPage {
            view.layer?.sublayerTransform = translation
        } else {
            view.layer?.transform = translation
        }
        CATransaction.commit()
    }

    private func animateSwipeView(_ view: NSView, from start: CGFloat, to end: CGFloat, orientation: SwipeOrientation) {
        positionSwipeView(view, at: end, orientation: orientation)
        guard !Anim.reduceMotion else { return }
        let axis = orientation == .horizontal ? "x" : "y"
        let property = view is ViewerDocumentPage ? "sublayerTransform" : "transform"
        let animation = CABasicAnimation(keyPath: "\(property).translation.\(axis)")
        animation.fromValue = start
        animation.toValue = end
        animation.duration = Self.swipeDuration
        animation.timingFunction = Anim.outQuint
        view.layer?.add(animation, forKey: "viewerSwipe")
    }

    /// Leave horizontal scrolling to an enlarged image; documents still scroll vertically.
    var acceptsSwipeNavigation: Bool {
        guard let item, item.files.count > 1, !compare, !help.visible else { return false }
        if let image = main as? ZoomImageView, let document = image.documentView {
            return document.bounds.width <= image.documentVisibleRect.width + 1
        }
        if let pdf = displayedContent as? PDFView, let scroll = pdf.documentView?.enclosingScrollView,
           let document = scroll.documentView {
            return document.bounds.width <= scroll.documentVisibleRect.width + 1
        }
        if let web = displayedContent as? WebDocView {
            return web.magnification <= 1 && web.hasHorizontalOverflow == false
        }
        return true
    }

    /// A mouse wheel changes fitted images; documents and enlarged images keep scrolling.
    var acceptsWheelNavigation: Bool {
        guard acceptsSwipeNavigation, let image = main as? ZoomImageView,
              let document = image.documentView else { return false }
        return document.bounds.height <= image.documentVisibleRect.height + 1
    }

    /// A new gesture can page past a document after reaching its matching edge.
    func acceptsVerticalSwipeNavigation(towardNext: Bool) -> Bool {
        if let web = displayedContent as? WebDocView {
            return web.acceptsVerticalPaging(towardNext: towardNext)
        }
        if let pdf = displayedContent as? PDFView, let scroll = pdf.documentView?.enclosingScrollView,
           let document = scroll.documentView {
            let visible = scroll.documentVisibleRect
            return towardNext == document.isFlipped
                ? visible.maxY >= document.bounds.maxY - 1
                : visible.minY <= document.bounds.minY + 1
        }
        return acceptsWheelNavigation
    }

    func zoomWithWheel(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .shift, .control]) == .command,
              !help.visible, let view = displayedContent, let window,
              view is ZoomImageView || view is WebDocView || view is PDFView else { return false }
        let location = event.window == nil ? window.convertPoint(fromScreen: event.locationInWindow) : event.locationInWindow
        let point = view.convert(location, from: nil)
        guard view.visibleRect.contains(point) else { return false }
        // A precise wheel reports pixels; a traditional wheel reports detents.
        let delta = event.scrollingDeltaY * (event.isDirectionInvertedFromDevice ? -1 : 1)
        guard event.momentumPhase.isEmpty, delta.isFinite, delta != 0 else { return true }
        let exponent = delta * (event.hasPreciseScrollingDeltas ? 0.01 : 0.18)
        let factor = exp(min(1, max(-1, exponent)))
        if let image = view as? ZoomImageView {
            image.zoom(by: factor, at: point)
        } else if let web = view as? WebDocView {
            let scale = min(5, max(0.4, web.magnification * factor))
            // WebKit applies this viewport translation before scaling its scroll position.
            let offset = web.magnification / scale - 1
            web.setMagnification(scale, centeredAt: NSPoint(x: point.x * offset, y: point.y * offset))
        } else if let pdf = view as? PDFView {
            pdf.zoom(by: factor, at: point)
        }
        return true
    }

    private var supportsZoom: Bool {
        compare || main is ZoomImageView || displayedContent is WebDocView || displayedContent is PDFView
    }

    func zoom(_ action: ZoomImageView.Action) {
        window?.cancelSwipeTracking()
        cancelSwipeAnimation()
        if compare {
            compareZoom.perform(action)
            return
        }
        (main as? ZoomImageView)?.perform(action)
        (displayedContent as? WebDocView)?.zoom(action)
        if let pdf = displayedContent as? PDFView {
            switch action {
            case .fit: pdf.autoScales = true
            case .actual: pdf.scaleFactor = 1
            case .zoomIn: pdf.zoomIn(nil)
            case .zoomOut: pdf.zoomOut(nil)
            }
        }
    }

    func toggleCompare() {
        guard let item, item.files.count > 1, item.allImages, let win = window else { return }
        compare.toggle()
        reloadContent()
        guard !win.styleMask.contains(.fullScreen) else { return }
        let screen = win.screen ?? NSScreen.main ?? NSScreen.screens[0]
        Anim.run(0.32, Anim.outQuint) { win.animator().setFrame(idealFrame(on: screen), display: true) }
    }

    func toggleFullScreen() {
        guard let win = window, win.isVisible, closeAnimation == nil else { return }
        win.cancelSwipeTracking()
        cancelSwipeAnimation()
        if let fullScreenHandler {
            fullScreenHandler()
        } else {
            win.toggleFullScreen(nil)
        }
    }

    func escape() {
        if help.visible {
            toggleHelp()
        } else if let win = window, win.styleMask.contains(.fullScreen) {
            win.toggleFullScreen(nil)
        } else {
            close()
        }
    }

    fileprivate func noteVideoPointerActivity(_ event: NSEvent) {
        guard let video = displayedContent as? VideoPlayerView else { return }
        let point = video.convert(event.locationInWindow, from: nil)
        guard video.bounds.contains(point) else { return }
        if event.type == .leftMouseDown {
            video.notePointerPress(at: point)
        } else {
            video.notePointerMove(at: point)
        }
    }

    fileprivate func handleVideoDoubleClick(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown, event.clickCount == 2,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              !help.visible, closeAnimation == nil,
              !isOverNavigation(event),
              let video = displayedContent as? VideoPlayerView,
              !video.isInVideoFullScreen else { return false }
        let point = video.convert(event.locationInWindow, from: nil)
        guard video.bounds.contains(point),
              !video.isInteractiveControl(atWindowPoint: event.locationInWindow) else { return false }
        toggleFullScreen()
        return true
    }

    fileprivate func handleVideoKey(_ event: NSEvent) -> Bool {
        guard [3, 49, 123, 124, 125, 126].contains(event.keyCode),
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              !help.visible, let video = displayedContent as? AVPlayerView else { return false }
        guard closeAnimation == nil, let player = video.player else { return true }
        switch event.keyCode {
        case 3:
            guard !event.isARepeat else { return true }
            toggleFullScreen()
        case 49:
            guard !event.isARepeat else { return true }
            if player.timeControlStatus == .paused {
                if let item = player.currentItem, item.duration.isNumeric, item.currentTime() >= item.duration {
                    player.seek(to: .zero)
                }
                player.play()
            } else {
                player.pause()
            }
        case 123, 124:
            guard let duration = player.currentItem?.duration, duration.isNumeric,
                  player.currentTime().isNumeric else { return true }
            let forward = event.keyCode == 124
            let offset = CMTime(value: forward ? 5 : -5, timescale: 1)
            let target = min(duration, max(.zero, player.currentTime() + offset))
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            let time = Duration.seconds(target.seconds.rounded(.down)).formatted(.time(pattern: .minuteSecond))
            showFeedback(ViewerFeedback(message: time, symbol: forward ? "goforward.5" : "gobackward.5"), timeout: 1)
        default: // ↓ / ↑
            let volume = player.isMuted ? 0 : player.volume
            player.volume = min(1, max(0, volume + (event.keyCode == 126 ? 0.1 : -0.1)))
            player.isMuted = false
            let percent = player.volume.formatted(.percent.precision(.fractionLength(0)))
            let message = L10n.tr("音量", "Volume") + " " + percent
            showFeedback(ViewerFeedback(message: message, symbol: player.volume == 0 ? "speaker.slash" : "speaker.wave.2"), timeout: 1)
        }
        return true
    }

    func toggleHelp() {
        window?.cancelSwipeTracking()
        cancelSwipeAnimation()
        if !help.visible {
            help.isVideo = displayedContent is AVPlayerView
            help.canJump = item?.origin?.canJump == true
        }
        withAnimation(.easeOut(duration: 0.16)) { help.visible.toggle() }
        helpHost?.isHidden = !help.visible
    }

    /// ↑ / ↓ follows the visible file list; single-file cards still walk history.
    func stepVertical(_ d: Int) {
        if (item?.files.count ?? 0) > 1 { step(d) } else { stepCard(d) }
    }

    /// ⌥↑ / ⌥↓: the next newer / older card.
    func stepCard(_ d: Int) {
        guard let item else { return }
        app?.openNeighbor(item.id, d, returningTo: sourceWindow)
    }

    func revealCurrent() {
        guard let item else { return }
        app?.reveal(item.id, only: compare ? nil : index)
    }

    func copyCurrent() {
        guard let item else { return }
        let copied = app?.copy(item.id, only: compare ? nil : index) == true
        let message = copied ? L10n.tr("已拷贝", "Copied") : L10n.tr("拷贝失败", "Copy Failed")
        showFeedback(ViewerFeedback(message: message, symbol: copied ? "checkmark" : "exclamationmark.circle"),
                     timeout: 1.6)
    }

    fileprivate func updateWrapFeedback(direction: Int, distance: CGFloat, wheelTimeout: TimeInterval? = nil) {
        guard distance > 0, wraps(direction) else {
            dismissWrapFeedback()
            return
        }
        let progress = min(1, distance / pageThreshold(direction))
        let message: String
        if progress == 1 {
            message = direction > 0 ? L10n.tr("松开回到第一张", "Release to return to the first item")
                                    : L10n.tr("松开前往最后一张", "Release to go to the last item")
        } else {
            message = direction > 0 ? L10n.tr("继续滚动，回到第一张", "Keep scrolling to return to the first item")
                                    : L10n.tr("继续滚动，前往最后一张", "Keep scrolling to go to the last item")
        }
        showFeedback(ViewerFeedback(message: message, symbol: "arrow.uturn.backward", progress: progress),
                     timeout: wheelTimeout)
    }

    private func showFeedback(_ content: ViewerFeedback, timeout: TimeInterval?) {
        guard let win = window, let container = win.contentView else { return }
        let previous = feedback?.rootView
        let host: ViewerFeedbackView
        if let feedback {
            host = feedback
            host.rootView = content
        } else {
            host = ViewerFeedbackView(rootView: content)
            feedback = host
            container.addSubview(host, positioned: .above, relativeTo: nil)
        }
        if previous?.message != content.message {
            host.identifier = NSUserInterfaceItemIdentifier(content.progress == nil ? "copyFeedback" : "wrapFeedback")
            host.setFrameSize(host.fittingSize)
            layoutContent()
        }
        if previous?.message != content.message || content.progress == nil {
            NSAccessibility.post(element: win, notification: .announcementRequested,
                                 userInfo: [.announcement: content.message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
        feedbackTimer?.invalidate()
        feedbackTimer = nil
        if let timeout {
            let timer = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in self?.dismissFeedback() }
            feedbackTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    fileprivate func dismissWrapFeedback() {
        if feedback?.rootView.progress != nil { dismissFeedback() }
    }

    private func dismissFeedback() {
        feedbackTimer?.invalidate()
        feedbackTimer = nil
        feedback?.removeFromSuperview()
        feedback = nil
    }

    // MARK: toolbar

    private enum ID {
        static let nav = NSToolbarItem.Identifier("nav")
        static let zoom = NSToolbarItem.Identifier("zoom")
        static let compare = NSToolbarItem.Identifier("compare")
        static let fullScreen = NSToolbarItem.Identifier("fullScreen")
        static let copy = NSToolbarItem.Identifier("copy")
        static let share = NSToolbarItem.Identifier("share")
        static let reveal = NSToolbarItem.Identifier("reveal")
        static let jump = NSToolbarItem.Identifier("jump")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, ID.nav, ID.zoom, ID.compare, ID.fullScreen, ID.copy, ID.share, ID.reveal, ID.jump]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ID.nav:
            let group = NSToolbarItemGroup(
                itemIdentifier: id,
                images: [symbol("chevron.left"), symbol("chevron.right")],
                selectionMode: .momentary,
                labels: [L10n.tr("上一个文件", "Previous file"), L10n.tr("下一个文件", "Next file")],
                target: self, action: #selector(navTapped(_:))
            )
            group.label = L10n.tr("切换", "Navigate")
            return group
        case ID.zoom:
            let labels = [L10n.tr("缩小  ⌘-", "Zoom Out  ⌘-"), L10n.tr("放大  ⌘=", "Zoom In  ⌘=")]
            let group = NSToolbarItemGroup(
                itemIdentifier: id,
                images: [symbol("minus.magnifyingglass"), symbol("plus.magnifyingglass")],
                selectionMode: .momentary,
                labels: labels,
                target: self, action: #selector(zoomTapped(_:))
            )
            group.label = L10n.tr("缩放", "Zoom")
            for (subitem, label) in zip(group.subitems, labels) {
                subitem.toolTip = label
            }
            return group
        case ID.compare:
            return button(id, "rectangle.split.2x1", L10n.tr("并排对比", "Compare"), #selector(compareTapped))
        case ID.fullScreen:
            return button(id, "arrow.up.left.and.arrow.down.right", L10n.tr("全屏  F", "Full Screen  F"), #selector(fullScreenTapped))
        case ID.copy:
            return button(id, "doc.on.doc", L10n.tr("拷贝  ⌘C", "Copy  ⌘C"), #selector(copyTapped))
        case ID.share:
            let share = NSSharingServicePickerToolbarItem(itemIdentifier: id)
            share.delegate = self
            share.label = L10n.tr("分享", "Share")
            share.toolTip = share.label
            return share
        case ID.reveal:
            return button(id, "folder", L10n.tr("在访达中显示  ⌘R", "Reveal in Finder  ⌘R"), #selector(revealTapped))
        case ID.jump:
            let item = NSToolbarItem(itemIdentifier: id)
            let label = L10n.tr("回到对话", "Jump to Session")
            let b = NSButton(title: label,
                             image: NSImage(systemSymbolName: "arrowshape.turn.up.backward.fill", accessibilityDescription: nil) ?? NSImage(),
                             target: self, action: #selector(jumpTapped))
            b.imagePosition = .imageLeading
            b.imageHugsTitle = true
            b.bezelStyle = .toolbar
            b.font = .systemFont(ofSize: 12.5, weight: .medium)
            item.view = b
            item.label = label
            item.isBordered = true
            return item
        default:
            return nil
        }
    }

    private func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
    }

    private func button(_ id: NSToolbarItem.Identifier, _ icon: String, _ label: String, _ action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: icon, accessibilityDescription: label)
        item.label = label
        item.toolTip = label
        item.isBordered = true
        item.target = self
        item.action = action
        return item
    }

    private func isToolbarItemVisible(_ t: NSToolbarItem) -> Bool {
        if #available(macOS 15.0, *) { return !t.isHidden }
        return true
    }

    private func setToolbarItemHidden(_ t: NSToolbarItem, _ hidden: Bool) {
        if #available(macOS 15.0, *) {
            t.isHidden = hidden
        }
    }

    private func syncToolbar(_ toolbar: NSToolbar?) {
        guard let toolbar else { return }
        if #unavailable(macOS 15.0) {
            let multi = (item?.files.count ?? 0) > 1
            var wanted: [NSToolbarItem.Identifier] = [.flexibleSpace]
            if multi && !compare { wanted.append(ID.nav) }
            if supportsZoom { wanted.append(ID.zoom) }
            if multi && item?.allImages == true { wanted.append(ID.compare) }
            wanted.append(contentsOf: [ID.fullScreen, ID.copy, ID.share, ID.reveal])
            if item?.origin?.canJump ?? false { wanted.append(ID.jump) }
            if toolbar.items.map(\.itemIdentifier) != wanted {
                while !toolbar.items.isEmpty { toolbar.removeItem(at: 0) }
                for (idx, id) in wanted.enumerated() {
                    toolbar.insertItem(withItemIdentifier: id, at: idx)
                }
            }
        }
        toolbar.items.forEach(refresh)
    }

    private func refresh(_ t: NSToolbarItem) {
        let multi = (item?.files.count ?? 0) > 1
        switch t.itemIdentifier {
        case ID.nav:
            setToolbarItemHidden(t, !multi || compare)
            t.label = L10n.tr("切换", "Navigate")
        case ID.zoom:
            setToolbarItemHidden(t, !supportsZoom)
            t.label = L10n.tr("缩放", "Zoom")
            if let group = t as? NSToolbarItemGroup, group.subitems.count == 2 {
                let labels = [L10n.tr("缩小  ⌘-", "Zoom Out  ⌘-"), L10n.tr("放大  ⌘=", "Zoom In  ⌘=")]
                for (subitem, label) in zip(group.subitems, labels) {
                    subitem.label = label
                    subitem.toolTip = label
                }
            }
        case ID.compare:
            setToolbarItemHidden(t, !multi || item?.allImages != true)
            t.image = NSImage(systemSymbolName: compare ? "square" : "rectangle.split.2x1", accessibilityDescription: nil)
            t.label = compare
                ? L10n.tr("单张查看  ⌘D", "Single View  ⌘D")
                : L10n.tr("并排对比  ⌘D", "Compare  ⌘D")
            t.toolTip = t.label
        case ID.fullScreen:
            let full = window?.styleMask.contains(.fullScreen) == true
            t.image = NSImage(systemSymbolName: full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                              accessibilityDescription: nil)
            t.label = full
                ? L10n.tr("退出全屏  ⎋", "Exit Full Screen  ⎋")
                : L10n.tr("全屏  F", "Full Screen  F")
            t.toolTip = t.label
        case ID.copy:
            t.label = L10n.tr("拷贝  ⌘C", "Copy  ⌘C")
            t.toolTip = t.label
        case ID.reveal:
            t.label = L10n.tr("在访达中显示  ⌘R", "Reveal in Finder  ⌘R")
            t.toolTip = t.label
        case ID.jump:
            setToolbarItemHidden(t, !(item?.origin?.canJump ?? false))
            let label = L10n.tr("回到对话", "Jump to Session")
            t.label = label
            (t.view as? NSButton)?.title = label
            if let c = item?.origin?.conversation {
                t.toolTip = "\(label)  ↩\n\(c)" + (item?.origin?.prompt.map { "\n\($0)" } ?? "")
            }
        default: break
        }
    }

    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        guard let item, item.files.indices.contains(index) else { return [] }
        return compare ? item.urls : [item.urls[index]]
    }

    @objc private func navTapped(_ sender: NSToolbarItemGroup) { step(sender.selectedIndex == 0 ? -1 : 1) }
    @objc private func zoomTapped(_ sender: NSToolbarItemGroup) { zoom(sender.selectedIndex == 0 ? .zoomOut : .zoomIn) }
    @objc private func compareTapped() { toggleCompare() }
    @objc private func fullScreenTapped() { toggleFullScreen() }
    @objc private func copyTapped() { copyCurrent() }
    @objc private func revealTapped() { revealCurrent() }
    @objc private func jumpTapped() { jumpBack() }

    /// Close the viewer and go back to the conversation; the card stays (read) for a while.
    func jumpBack() {
        guard let item, item.origin?.canJump == true else { return }
        sourceWindow = nil
        previousApplication = nil
        close()
        app?.jump(item.id)
    }
}

final class ViewerWindow: NSPanel {
    weak var viewer: Viewer?

    private enum SwipeAxis {
        case undecided, horizontal, vertical, scrolling, discarded

        var consumesScroll: Bool { self == .horizontal || self == .vertical || self == .discarded }
    }
    private var swipeAxis = SwipeAxis.undecided
    private var swipeX: CGFloat = 0
    private var swipeY: CGFloat = 0
    private var allowsHorizontalSwipe = false
    private var allowsVerticalSwipe = false
    private var trackingSwipe = false
    private var undecidedScrollEvents: [NSEvent] = []
    private struct WheelBurst {
        let direction: Int
        let precise: Bool
        var lastInput: TimeInterval
        var distance: CGFloat = 0
        var didNavigate = false
    }
    private var wheelBurst: WheelBurst?
    private static let wheelIdleTimeout: TimeInterval = 0.65

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func close() {
        viewer?.clearContent()
        super.close()
    }

    func resetSwipe(cancelAnimation: Bool = true) {
        trackingSwipe = false
        swipeAxis = .undecided
        swipeX = 0
        swipeY = 0
        undecidedScrollEvents.removeAll()
        wheelBurst = nil
        if cancelAnimation { viewer?.cancelSwipeAnimation() }
    }

    func cancelSwipeTracking() {
        wheelBurst = nil
        // The buffered prefix never reached a child, so its suffix must not either.
        if trackingSwipe, swipeAxis == .undecided { swipeAxis = .discarded }
        trackingSwipe = false
        undecidedScrollEvents.removeAll()
    }

    // Intercept before NSScrollView, PDFKit or WebKit consumes the scroll event.
    override func sendEvent(_ event: NSEvent) {
        // WebKit and SwiftUI can otherwise consume arrows before the window sees them.
        if event.type == .keyDown {
            if handleCloseShortcut(event) || handleFullScreenShortcut(event) || viewer?.handleVideoKey(event) == true { return }
            if [123, 124, 125, 126].contains(event.keyCode),
               event.modifierFlags.intersection([.command, .control]).isEmpty {
                keyDown(with: event)
                return
            }
        }
        if [.leftMouseDown, .rightMouseDown, .magnify, .smartMagnify].contains(event.type) {
            cancelSwipeTracking()
            viewer?.cancelSwipeAnimation()
        }
        if event.type == .leftMouseDown, viewer?.handleVideoDoubleClick(event) == true {
            return
        }
        if [.leftMouseDown, .mouseMoved].contains(event.type) {
            viewer?.noteVideoPointerActivity(event)
        }
        if event.type == .scrollWheel {
            if viewer?.zoomWithWheel(event) == true {
                cancelSwipeTracking()
                return
            }
            if handleWheel(event) || handleSwipe(event) { return }
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleCloseShortcut(event) || handleFullScreenShortcut(event) || super.performKeyEquivalent(with: event)
    }

    private func handleFullScreenShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command, .control],
              let viewer else { return false }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        guard key == "f" || (key.isEmpty && event.keyCode == 3) else { return false }
        viewer.toggleFullScreen()
        return true
    }

    private func handleCloseShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
              let viewer else { return false }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        guard key == "w" || (key.isEmpty && event.keyCode == 13) else { return false }
        viewer.close()
        return true
    }

    private func handleWheel(_ event: NSEvent) -> Bool {
        // Smooth mouse wheels may use pixel deltas too; gesture phases distinguish trackpads.
        guard event.phase.isEmpty, event.momentumPhase.isEmpty else { return false }
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
              let viewer, !viewer.isOverNavigation(event), viewer.acceptsWheelNavigation else {
            if wheelBurst != nil {
                wheelBurst = nil
                viewer?.dismissWrapFeedback()
            }
            return false
        }
        let direction = event.scrollingDeltaY < 0 ? 1 : -1
        let precise = event.hasPreciseScrollingDeltas
        var burst: WheelBurst
        if let last = wheelBurst, last.direction == direction, last.precise == precise,
           event.timestamp - last.lastInput < (last.didNavigate ? Viewer.swipeDuration : Self.wheelIdleTimeout) {
            if last.didNavigate { return true }
            burst = last
        } else {
            cancelSwipeTracking()
            viewer.cancelSwipeAnimation()
            burst = WheelBurst(direction: direction, precise: precise, lastInput: event.timestamp)
        }
        burst.lastInput = event.timestamp
        // Acceleration and the system's lines-per-notch setting can inflate a single event.
        let magnitude = abs(event.scrollingDeltaY)
        burst.distance += precise ? min(magnitude, 48) : min(magnitude, 1) * 32
        if burst.distance >= viewer.pageThreshold(direction) {
            burst.didNavigate = true
            viewer.finishSwipe(direction, orientation: viewer.hasThumbnailSidebar ? .vertical : .horizontal)
        } else {
            viewer.updateWrapFeedback(direction: direction, distance: burst.distance, wheelTimeout: Self.wheelIdleTimeout)
        }
        // Reload resets tracking. Save the commit time so its animation can finish before accumulating again.
        wheelBurst = burst
        return true
    }

    private func handleSwipe(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas else { return false }
        // Momentum belongs to the gesture that just ended, never to a new file.
        if !event.momentumPhase.isEmpty { return swipeAxis.consumesScroll }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            // Resting fingers can emit mayBegin while the release animation runs.
            resetSwipe(cancelAnimation: event.phase.contains(.began))
            guard let viewer else { return false }
            let overNavigation = viewer.isOverNavigation(event)
            allowsHorizontalSwipe = !overNavigation && viewer.acceptsSwipeNavigation
            allowsVerticalSwipe = !overNavigation && viewer.hasThumbnailSidebar
                && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            trackingSwipe = allowsHorizontalSwipe || allowsVerticalSwipe
        }
        guard !event.phase.isEmpty else { return false }
        guard trackingSwipe else { return swipeAxis.consumesScroll }

        let fingerDirection: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        swipeX += event.scrollingDeltaX * fingerDirection
        // A positive non-natural vertical scroll delta corresponds to an upward finger swipe.
        swipeY -= event.scrollingDeltaY * fingerDirection
        if swipeAxis == .undecided, max(abs(swipeX), abs(swipeY)) >= 8 {
            if abs(swipeX) > abs(swipeY) * 1.2 {
                swipeAxis = allowsHorizontalSwipe ? .horizontal : .scrolling
            } else {
                let canPage = allowsVerticalSwipe && viewer?.acceptsVerticalSwipeNavigation(towardNext: swipeY > 0) == true
                swipeAxis = canPage ? .vertical : .scrolling
            }
        }

        let finished = event.phase.contains(.ended) || event.phase.contains(.cancelled)
        if swipeAxis == .undecided {
            undecidedScrollEvents.append(event)
            if finished {
                trackingSwipe = false
                undecidedScrollEvents.forEach { super.sendEvent($0) }
                undecidedScrollEvents.removeAll()
            }
            return true
        }
        // A child receives either a complete scroll stream or none of it.
        if swipeAxis == .scrolling { undecidedScrollEvents.forEach { super.sendEvent($0) } }
        undecidedScrollEvents.removeAll()
        if swipeAxis == .horizontal { viewer?.updateSwipe(swipeX) }
        if swipeAxis == .vertical { viewer?.updateSwipe(swipeY, orientation: .vertical) }
        if finished {
            trackingSwipe = false
            let cancelled = event.phase.contains(.cancelled)
            if swipeAxis == .horizontal { viewer?.releaseSwipe(swipeX, cancelled: cancelled) }
            if swipeAxis == .vertical { viewer?.releaseSwipe(swipeY, orientation: .vertical, cancelled: cancelled) }
        }
        return swipeAxis.consumesScroll
    }

    override func keyDown(with e: NSEvent) {
        guard let v = viewer else { return super.keyDown(with: e) }
        if handleCloseShortcut(e) || v.handleVideoKey(e) { return }
        let m = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let cmd = m == .command
        let plain = m.isEmpty || m == .shift
        switch e.keyCode {
        case 53: v.escape()                                         // esc
        case 49 where plain: v.close()                             // space
        case 123 where plain: v.step(-1)                            // ←
        case 124 where plain: v.step(1)                             // →
        case 126 where plain: v.stepVertical(-1)                    // ↑ previous file
        case 125 where plain: v.stepVertical(1)                     // ↓ next file
        case 126 where m == .option: v.stepCard(-1)                 // ⌥↑ newer card
        case 125 where m == .option: v.stepCard(1)                  // ⌥↓ older card
        case 36 where m.isEmpty, 76 where m.isEmpty, 36 where cmd: v.jumpBack()   // ↩ back to the conversation
        case 8 where cmd: v.copyCurrent()                           // ⌘C
        case 15 where cmd: v.revealCurrent()                        // ⌘R
        case 2 where cmd: v.toggleCompare()                         // ⌘D
        case 3 where m.isEmpty: v.toggleFullScreen()                // F
        case 51 where cmd: v.close()                               // ⌘⌫
        case 29 where cmd: v.zoom(.fit)                             // ⌘0
        case 18 where cmd: v.zoom(.actual)                          // ⌘1
        case 24 where cmd: v.zoom(.zoomIn)                          // ⌘=
        case 27 where cmd: v.zoom(.zoomOut)                         // ⌘-
        case 44 where m == .shift: v.toggleHelp()                   // ?
        default: super.keyDown(with: e)
        }
    }

    // Esc that a web / PDF view passes up the responder chain.
    override func cancelOperation(_ sender: Any?) { viewer?.escape() }
}

private final class ViewerContentView: NSView {
    var onResize: (() -> Void)?

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        onResize?()
    }
}

/// Keep the transition on the host layer while PDFKit and WebKit lay out their content.
final class ViewerDocumentPage: NSView {
    let document: NSView
    private var tornDown = false

    init(_ document: NSView) {
        self.document = document
        super.init(frame: .zero)
        wantsLayer = true
        document.frame = bounds
        document.autoresizingMask = [.width, .height]
        addSubview(document)
    }

    required init?(coder: NSCoder) { fatalError() }

    func pausePlayback() {
        if let web = document as? WebDocView {
            web.pauseMedia()
        } else if let video = document as? AVPlayerView {
            video.player?.pause()
        }
    }

    func stopMedia() {
        if document is QLPreviewView { teardown() } else { pausePlayback() }
    }

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        if let ql = document as? QLPreviewView {
            ql.close()
        } else if let web = document as? WebDocView {
            web.teardown()
        } else if let video = document as? VideoPlayerView {
            video.teardown()
        } else if let video = document as? AVPlayerView {
            video.player?.pause()
            video.player = nil
        }
    }
}

/// Auto-hides the floating playback controls when idle and exposes AVKit's full-screen toggle.
final class VideoPlayerView: AVPlayerView, AVPlayerViewDelegate {
    var autoHideDelay: TimeInterval = 2.5
    var mouseExitHideDelay: TimeInterval = 0.35
    private var hideTimer: Timer?
    private var pointerTrackingArea: NSTrackingArea?
    private var lastPointerLocation: NSPoint?
    private var controlsHiddenObservation: NSKeyValueObservation?
    private weak var observedControlsView: NSView?
    private var visibilityGeneration = 0
    private(set) var isInVideoFullScreen = false
    private(set) var areControlsHidden = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        controlsStyle = .floating
        showsFullScreenToggleButton = true
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        hideTimer?.invalidate()
        controlsHiddenObservation?.invalidate()
    }

    override func layout() {
        super.layout()
        syncFloatingControlsVisibility()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            revealControls()
        } else {
            cancelAutoHide()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        notePointerMove(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        notePointerMove(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        notePointerPress(at: convert(event.locationInWindow, from: nil))
        super.mouseDown(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        lastPointerLocation = nil
        scheduleAutoHide(after: mouseExitHideDelay)
    }

    func notePointerMove(at pointInView: NSPoint) {
        // Hiding floating controls can synthesize a mouseMoved/mouseEntered at the same point.
        if areControlsHidden, let last = lastPointerLocation,
           hypot(pointInView.x - last.x, pointInView.y - last.y) < 2 {
            return
        }
        lastPointerLocation = pointInView
        revealControls()
    }

    func notePointerPress(at pointInView: NSPoint) {
        lastPointerLocation = pointInView
        revealControls()
    }

    func isInteractiveControl(atWindowPoint locationInWindow: NSPoint) -> Bool {
        guard let hitPoint = superview?.convert(locationInWindow, from: nil),
              var view = hitTest(hitPoint) else { return false }
        while view !== self {
            if view is NSControl || view is NSVisualEffectView {
                return true
            }
            let className = NSStringFromClass(type(of: view))
            if className.contains("Control") || className.contains("Button")
                || className.contains("Slider") || className.contains("Scrubber")
                || className.contains("Timeline") || className.contains("Volume")
                || className.contains("Movable") {
                return true
            }
            guard let parent = view.superview else { break }
            view = parent
        }
        return false
    }

    func revealControls(autoHide: Bool = true) {
        cancelAutoHide()
        if controlsStyle != .floating { controlsStyle = .floating }
        setControlsHidden(false, animated: true)
        if autoHide && !isInVideoFullScreen {
            scheduleAutoHide(after: autoHideDelay)
        }
    }

    func teardown() {
        cancelAutoHide()
        controlsHiddenObservation?.invalidate()
        controlsHiddenObservation = nil
        observedControlsView = nil
        player?.pause()
        player = nil
    }

    /// Locates AVKit's floating controls container (e.g. `AVMovableView`) without touching video/Live Text subviews.
    var floatingControlsContainer: NSView? {
        findFloatingControlsContainer(in: self)
    }

    private func findFloatingControlsContainer(in view: NSView) -> NSView? {
        for subview in view.subviews {
            let className = NSStringFromClass(type(of: subview))
            if className.contains("PlaybackContentContainer") || className.hasPrefix("VK") {
                continue
            }
            if className.contains("AVMovableView")
                || className.contains("FloatingPlaybackControls")
                || className.contains("ControlsContainer") {
                return subview
            }
            if let found = findFloatingControlsContainer(in: subview) {
                return found
            }
        }
        return nil
    }

    private func observeControlsViewIfNeeded(_ controlsView: NSView) {
        guard observedControlsView !== controlsView else { return }
        controlsHiddenObservation?.invalidate()
        observedControlsView = controlsView
        controlsHiddenObservation = controlsView.observe(\.isHidden, options: [.new]) { [weak self] view, _ in
            guard let self, self.areControlsHidden, !view.isHidden else { return }
            view.alphaValue = 0
            view.isHidden = true
        }
    }

    private func syncFloatingControlsVisibility() {
        guard let controlsView = floatingControlsContainer else { return }
        observeControlsViewIfNeeded(controlsView)
        if areControlsHidden {
            controlsView.alphaValue = 0
            if !controlsView.isHidden { controlsView.isHidden = true }
        }
    }

    private func setControlsHidden(_ hidden: Bool, animated: Bool) {
        let changed = areControlsHidden != hidden
        areControlsHidden = hidden
        guard let controlsView = floatingControlsContainer else { return }
        observeControlsViewIfNeeded(controlsView)

        visibilityGeneration &+= 1
        let gen = visibilityGeneration
        let shouldAnimate = animated && changed && !Anim.reduceMotion && window != nil

        if hidden {
            guard !controlsView.isHidden else {
                controlsView.alphaValue = 0
                return
            }
            if shouldAnimate {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.18
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    controlsView.animator().alphaValue = 0
                }, completionHandler: { [weak self, weak controlsView] in
                    Task { @MainActor in
                        guard let self, self.visibilityGeneration == gen, self.areControlsHidden else { return }
                        controlsView?.alphaValue = 0
                        controlsView?.isHidden = true
                    }
                })
            } else {
                controlsView.alphaValue = 0
                controlsView.isHidden = true
            }
        } else {
            controlsView.isHidden = false
            if shouldAnimate {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.14
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    controlsView.animator().alphaValue = 1
                }
            } else {
                controlsView.alphaValue = 1
            }
        }
    }

    private func cancelAutoHide() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    private func scheduleAutoHide(after delay: TimeInterval) {
        cancelAutoHide()
        guard !isInVideoFullScreen else { return }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.hideControlsIfIdle()
        }
        hideTimer = timer
        // Default mode pauses the timer while menus or slider drags are tracking.
        RunLoop.main.add(timer, forMode: .default)
    }

    private var hasBlockingChildWindow: Bool {
        window?.childWindows?.contains { child in
            guard child.isVisible else { return false }
            let name = NSStringFromClass(type(of: child))
            return name.contains("Popover") || name.contains("Menu")
        } == true
    }

    private func hideControlsIfIdle() {
        hideTimer = nil
        guard !isInVideoFullScreen else { return }
        if NSEvent.pressedMouseButtons != 0 || window?.attachedSheet != nil || hasBlockingChildWindow {
            scheduleAutoHide(after: autoHideDelay)
            return
        }
        if lastPointerLocation == nil, let window {
            let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            if bounds.contains(point) {
                lastPointerLocation = point
            }
        }
        // Keep controlsStyle = .floating instead of switching to .none; toggling to .none on macOS
        // tears down the inner buttons while leaving an empty NSGlassView shell visible on screen.
        setControlsHidden(true, animated: true)
    }

    func playerViewWillEnterFullScreen(_ playerView: AVPlayerView) {
        isInVideoFullScreen = true
        cancelAutoHide()
        if controlsStyle != .floating { controlsStyle = .floating }
        setControlsHidden(false, animated: false)
    }

    func playerViewDidExitFullScreen(_ playerView: AVPlayerView) {
        isInVideoFullScreen = false
        revealControls()
    }
}

private final class ViewerFeedbackView: NSHostingView<ViewerFeedback> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct ViewerFeedback: View {
    let message: String
    let symbol: String
    var progress: CGFloat? = nil

    var body: some View {
        Label {
            Text(message)
        } icon: {
            if let progress {
                ZStack {
                    Circle().stroke(.secondary.opacity(0.35), lineWidth: 2)
                    Circle().trim(from: 0, to: progress)
                        .stroke(.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(Anim.reduceMotion ? nil : .easeOut(duration: 0.1), value: progress)
                    Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                }
                .frame(width: 18, height: 18)
            } else {
                Image(systemName: symbol)
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
        .fixedSize()
    }
}

private extension PDFView {
    func zoom(by factor: CGFloat, at point: NSPoint) {
        guard let page = page(for: point, nearest: true),
              let scroll = documentView?.enclosingScrollView else { return }
        let anchor = convert(point, to: page)
        autoScales = false
        scaleFactor = min(maxScaleFactor, max(minScaleFactor, scaleFactor * factor))
        layoutDocumentView()
        let clip = scroll.contentView
        let original = clip.convert(point, from: self)
        let scaled = clip.convert(convert(anchor, from: page), from: self)
        let bounds = clip.bounds.offsetBy(dx: scaled.x - original.x, dy: scaled.y - original.y)
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
    }
}

// MARK: - zoomable image

/// Pinch / ⌘± to zoom, double-click toggles fit ↔ 1:1 pixels, stays centered.
final class ZoomImageView: NSScrollView {
    enum Action { case fit, actual, zoomIn, zoomOut }

    private let imageView = NSImageView()
    private var natural = NSSize.zero
    private var fitting = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        contentView = CenteringClipView()
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        allowsMagnification = true
        minMagnification = 0.05
        maxMagnification = 16
        automaticallyAdjustsContentInsets = false
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = true
        imageView.wantsLayer = true
        imageView.layer?.magnificationFilter = .nearest
        documentView = imageView
        NotificationCenter.default.addObserver(self, selector: #selector(willMagnify),
                                               name: NSScrollView.willStartLiveMagnifyNotification, object: self)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setImage(_ img: NSImage) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let rep = img.representations.first
        let px = NSSize(width: CGFloat(rep?.pixelsWide ?? Int(img.size.width)), height: CGFloat(rep?.pixelsHigh ?? Int(img.size.height)))
        natural = px.width > 0 ? NSSize(width: px.width / scale, height: px.height / scale) : img.size
        imageView.image = img
        imageView.frame = NSRect(origin: .zero, size: natural)
        fitting = true
        fit()
    }

    private var fitScale: CGFloat {
        let w = bounds.width - 32
        let h = bounds.height - 24
        guard natural.width > 0, natural.height > 0, w > 0, h > 0 else { return 1 }
        return min(w / natural.width, h / natural.height)
    }

    private func fit(animated: Bool = false) {
        let scale = fitScale
        // Keep fit and the next smart zoom reachable even for very small images.
        if scale * 2 > maxMagnification { maxMagnification = scale * 2 }
        if scale < minMagnification { minMagnification = scale }
        if animated {
            animator().magnification = scale
        } else {
            magnification = scale
        }
    }

    func perform(_ action: Action) {
        switch action {
        case .fit: fitting = true; fit(animated: true)
        case .actual: fitting = false; animator().magnification = 1
        case .zoomIn: fitting = false; animator().magnification = min(maxMagnification, magnification * 1.5)
        case .zoomOut: fitting = false; animator().magnification = max(minMagnification, magnification / 1.5)
        }
    }

    // AppKit can lay out the scroll view between updates of the same pinch.
    @objc private func willMagnify() { fitting = false }

    func zoom(by factor: CGFloat, at point: NSPoint) {
        fitting = false
        setMagnification(magnification * factor, centeredAt: contentView.convert(point, from: self))
    }

    override func layout() {
        super.layout()
        if fitting { fit() }
    }

    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 {
            toggleZoom(to: 1, at: e.locationInWindow)
        } else {
            super.mouseDown(with: e)
        }
    }

    override func smartMagnify(with event: NSEvent) {
        let fitted = fitScale
        toggleZoom(to: fitted < 1 ? 1 : fitted * 2, at: event.locationInWindow)
    }

    private func toggleZoom(to scale: CGFloat, at location: NSPoint) {
        if fitting || magnification < scale - 0.01 {
            fitting = false
            let point = contentView.convert(location, from: nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                animator().setMagnification(scale, centeredAt: point)
            }
        } else {
            perform(.fit)
        }
    }
}

/// Keeps a smaller-than-viewport document centered instead of pinned bottom-left.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposed)
        guard let doc = documentView else { return r }
        if r.width > doc.frame.width { r.origin.x = (doc.frame.width - r.width) / 2 }
        if r.height > doc.frame.height { r.origin.y = (doc.frame.height - r.height) / 2 }
        return r
    }
}

// MARK: - SwiftUI pieces

final class StripModel: ObservableObject {
    @Published var thumbs: [NSImage] = []
    @Published var names: [String] = []
    @Published var selected = 0
    @Published var visible = false
    @Published var sidebar = false
}

struct FilmstripView: View {
    @ObservedObject var m: StripModel
    var pick: (Int) -> Void
    private let pillShape = RoundedRectangle(cornerRadius: 17, style: .continuous)

    var body: some View {
        if m.visible {
            if m.sidebar {
                sidebar
            } else {
                ViewThatFits(in: .horizontal) {
                    row
                        .padding(8)
                        .peekGlass(in: pillShape)
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            row.padding(8)
                        }
                        .peekGlass(in: pillShape)
                        .padding(.horizontal, 16)
                        .onChange(of: m.selected) { _, idx in
                            withAnimation(.snappy(duration: 0.22)) {
                                proxy.scrollTo(idx, anchor: .center)
                            }
                        }
                    }
                }
                .animation(.snappy(duration: 0.22), value: m.selected)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var sidebar: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 8) {
                    ForEach(Array(m.names.enumerated()), id: \.offset) { i, name in
                        Button { pick(i) } label: {
                            VStack(spacing: 7) {
                                Group {
                                    if i < m.thumbs.count {
                                        Image(nsImage: m.thumbs[i]).resizable().aspectRatio(contentMode: .fit)
                                    } else {
                                        Color.white.opacity(0.06)
                                    }
                                }
                                .frame(width: 132, height: thumbnailHeight(i))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                Text(name)
                                    .font(.system(size: 11, weight: i == m.selected ? .semibold : .regular))
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(i == m.selected ? Color.accentColor.opacity(0.24) : .clear))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(i == m.selected ? Color.accentColor : .clear, lineWidth: 1.5))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(name)
                        .accessibilityLabel(name)
                        .accessibilityAddTraits(i == m.selected ? .isSelected : [])
                        .id(i)
                    }
                }
                .padding(10)
            }
            .background(Color(nsColor: NSColor(white: 0.105, alpha: 1)))
            .overlay(alignment: .trailing) { Color.white.opacity(0.08).frame(width: 1) }
            .onAppear { proxy.scrollTo(m.selected, anchor: .center) }
            .onChange(of: m.selected) { _, idx in
                withAnimation(.snappy(duration: 0.22)) { proxy.scrollTo(idx, anchor: .center) }
            }
        }
    }

    private func thumbnailHeight(_ index: Int) -> CGFloat {
        guard index < m.thumbs.count else { return 100 }
        let size = m.thumbs[index].size
        guard size.width > 0 else { return 100 }
        return min(220, max(54, 132 * size.height / size.width))
    }

    private var row: some View {
        HStack(spacing: 8) {
            ForEach(Array(m.names.enumerated()), id: \.offset) { i, name in
                Button { pick(i) } label: {
                    Group {
                        if i < m.thumbs.count {
                            Image(nsImage: m.thumbs[i]).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.white.opacity(0.08)
                        }
                    }
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(i == m.selected ? Color.white : Color.white.opacity(0.15),
                                          lineWidth: i == m.selected ? 2 : 0.5)
                    )
                    .opacity(i == m.selected ? 1 : 0.6)
                    .scaleEffect(i == m.selected ? 1 : 0.92)
                }
                .buttonStyle(.plain)
                .help(name)
                .accessibilityLabel(name)
                .accessibilityAddTraits(i == m.selected ? .isSelected : [])
                .id(i)
            }
        }
    }
}

final class CompareZoomModel: ObservableObject {
    @Published var scale: CGFloat = 1
    @Published var liveMagnification: CGFloat = 1

    var effectiveScale: CGFloat {
        min(8, max(0.5, scale * liveMagnification))
    }

    func reset() {
        scale = 1
        liveMagnification = 1
    }

    func perform(_ action: ZoomImageView.Action) {
        withAnimation(.easeOut(duration: 0.18)) {
            switch action {
            case .fit, .actual:
                scale = 1
                liveMagnification = 1
            case .zoomIn:
                scale = min(8, scale * 1.4)
            case .zoomOut:
                scale = max(0.5, scale / 1.4)
            }
        }
    }
}

struct CompareView: View {
    let images: [NSImage]
    var names: [String] = []
    @ObservedObject var zoom = CompareZoomModel()
    var pick: (Int) -> Void = { _ in }

    var body: some View {
        GeometryReader { geo in
            let baseW = max(1, geo.size.width - 32)
            let baseH = max(1, geo.size.height - 32)
            let s = zoom.effectiveScale
            ScrollView([.horizontal, .vertical], showsIndicators: s > 1.01) {
                HStack(spacing: 16) {
                    ForEach(Array(images.enumerated()), id: \.offset) { i, img in
                        Button { pick(i) } label: {
                            VStack(spacing: 8) {
                                Image(nsImage: img)
                                    .resizable()
                                    .interpolation(.high)
                                    .aspectRatio(contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                                if i < names.count, !names[i].isEmpty {
                                    Text(names[i])
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.75))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(.white.opacity(0.08)))
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(i < names.count ? names[i] : "\(i + 1)")
                    }
                }
                .padding(16)
                .frame(width: baseW * s + 32, height: baseH * s + 32)
            }
            .gesture(
                MagnificationGesture()
                    .onChanged { value in zoom.liveMagnification = value }
                    .onEnded { value in
                        zoom.scale = min(8, max(0.5, zoom.scale * value))
                        zoom.liveMagnification = 1
                    }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - shortcut cheat sheet (?)

final class HelpModel: ObservableObject {
    @Published var visible = false
    var isVideo = false
    var canJump = false
}

struct ShortcutSheet: View {
    @ObservedObject var m: HelpModel

    private var viewer: [(String, String)] {
        var rows = [
            ("⎋  ⌘W  ⌘⌫", L10n.tr("关闭查看器", "Close viewer")),
            ("Space", m.isVideo ? L10n.tr("播放或暂停", "Play or pause") : L10n.tr("关闭查看器", "Close viewer")),
            ("←  →", m.isVideo ? L10n.tr("后退或前进 5 秒", "Back or forward 5 seconds") : L10n.tr("切换这张卡里的文件", "Previous / next file")),
            (L10n.tr("双指左右滑", "Swipe ↔"), L10n.tr("上一张 / 下一张文件", "Previous / next file")),
            m.isVideo ? ("⇧←  ⇧→", L10n.tr("切换这张卡里的文件", "Previous / next file"))
                      : (L10n.tr("滚轮上下", "Scroll ↕"), L10n.tr("上一张 / 下一张图片", "Previous / next image")),
            ("↑  ↓", m.isVideo ? L10n.tr("调高或调低音量 10%", "Volume up or down by 10%") : L10n.tr("切换文件（单文件时切换卡片）", "Files (cards for single files)")),
            ("⌥↑  ⌥↓", L10n.tr("上一张 / 下一张卡", "Newer / older card")),
            ("⌘C", L10n.tr("拷贝", "Copy")),
            ("⌘R", L10n.tr("在访达中显示", "Reveal in Finder")),
            ("⌘D", L10n.tr("并排对比", "Side-by-side compare")),
            ("F  ⌃⌘F", m.isVideo ? L10n.tr("全屏 / 退出全屏（也可双击视频）", "Toggle full screen (or double-click video)") : L10n.tr("全屏 / 退出全屏", "Toggle full screen")),
            ("⌘0  ⌘1", L10n.tr("适应窗口 / 原始像素", "Fit to window / 1:1 pixels")),
            ("⌘=  ⌘-", L10n.tr("放大 / 缩小", "Zoom in / out")),
            (L10n.tr("⌘ + 滚轮", "⌘ + Wheel"), L10n.tr("在指针处缩放图片或文档", "Zoom image or document at pointer")),
        ]
        if m.canJump { rows.append(("↩", L10n.tr("回到对话", "Jump to session"))) }
        return rows
    }

    private var global: [(String, String)] {
        let names: [(Hotkeys.Action, String)] = [
            (.open, L10n.tr("打开最新卡片", "Open newest card")),
            (.recent, RecentPanel.displayTitle),
            (.tuck, L10n.tr("暂时收起 / 恢复", "Tuck aside / restore")),
            (.closeAll, L10n.tr("全部关闭", "Close all")),
        ]
        return names.compactMap { a, label in Hotkeys.shared.active[a].map { ($0.display, label) } }
    }

    var body: some View {
        if m.visible {
            VStack(alignment: .leading, spacing: 14) {
                section(viewer)
                if !global.isEmpty {
                    Divider().opacity(0.5)
                    section(global)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .peekGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
    }

    private func section(_ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 14) {
                    HStack(spacing: 4) {
                        ForEach(row.0.split(separator: " ").map(String.init), id: \.self) { key in
                            Text(key)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 6)
                                .frame(minWidth: 22, minHeight: 20)
                                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.1)))
                        }
                    }
                    .frame(width: 104, alignment: .trailing)
                    Text(row.1).font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
            }
        }
    }
}
