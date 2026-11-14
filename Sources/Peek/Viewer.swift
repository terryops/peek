import AppKit
import PDFKit
import Quartz
import SwiftUI

/// Peek's own viewer. Peek is an accessory app, so this never adds a Dock icon,
/// and closing it hands focus back to whatever you were using before.
final class Viewer: NSObject, NSWindowDelegate, NSToolbarDelegate {
    static let shared = Viewer()
    weak var app: App?

    private var window: ViewerWindow?
    private var item: PeekItem?
    private var index = 0
    private var compare = false
    private var main: NSView?
    private let strip = StripModel()
    private var stripHost: NSHostingView<FilmstripView>?
    private let help = HelpModel()
    private var helpHost: NSView?
    private var swipeOffset: CGFloat = 0
    private var swipeOutgoing: NSView?
    private var swipeAnimationGeneration = 0

    var isOpen: Bool { window?.isVisible ?? false }
    /// Debug only: open without taking the keyboard.
    var takesKey = true
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
            "help": help.visible,
            "item": item?.displayTitle ?? "",
            "key": win.isKeyWindow,
            "appActive": NSApp.isActive,
            "content": main.map { String(describing: type(of: $0)) } ?? "-",
            "magnification": (main as? ZoomImageView)?.magnification ?? 0,
            "swipeOffset": swipeOffset,
            "toolbar": win.toolbar?.items.filter { !$0.isHidden }.map(\.label) ?? [],
        ]
    }

    // MARK: open / close

    func show(_ item: PeekItem, from origin: NSRect?) {
        let reopenSame = isOpen && self.item?.id == item.id
        self.item = item
        let screen = origin.flatMap { r in NSScreen.screens.first { $0.frame.intersects(r) } } ?? NSScreen.main ?? NSScreen.screens[0]
        if !reopenSame {
            index = 0
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            compare = item.files.count > 1 && item.allImages && displayID.map { CGDisplayIsBuiltin($0) == 0 } == true
        }

        let win = window ?? makeWindow()
        win.resetSwipe()
        let target = idealFrame(on: screen)
        reloadContent()

        // A non-activating panel: it takes the keyboard (esc, arrows, ⌘C) while the app
        // you were in stays active, so closing it drops you right back where you were.
        defer { win.toolbar?.items.forEach(refresh) }
        if win.isVisible {
            if !reopenSame { Anim.run(0.32, Anim.outQuint) { win.animator().setFrame(target, display: true) } }
            win.orderFrontRegardless()
            if takesKey { win.makeKey() }
            return
        }
        let start = origin ?? target.insetBy(dx: target.width * 0.06, dy: target.height * 0.06)
        win.setFrame(start, display: false)
        win.alphaValue = 0
        win.orderFrontRegardless()
        if takesKey { win.makeKey() }
        Anim.run(Anim.reduceMotion ? 0.15 : 0.34, Anim.outExpo) {
            win.animator().setFrame(target, display: true)
            win.animator().alphaValue = 1
        }
    }

    func close() {
        guard let win = window, win.isVisible else { return }
        win.resetSwipe()
        let f = win.frame
        Anim.run(0.16, Anim.inCubic, {
            win.animator().alphaValue = 0
            win.animator().setFrame(f.insetBy(dx: f.width * 0.03, dy: f.height * 0.03), display: true)
        }, done: {
            win.orderOut(nil)
            win.alphaValue = 1
        })
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        done()
        return false
    }

    /// Item changed on disk (deleted / cleaned up): close if it's gone.
    func itemsChanged(_ items: [PeekItem]) {
        guard let current = item, isOpen else { return }
        if let fresh = items.first(where: { $0.id == current.id }) {
            item = fresh
        } else {
            close()
        }
    }

    // MARK: window

    private func makeWindow() -> ViewerWindow {
        let win = ViewerWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
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
        win.collectionBehavior = [.moveToActiveSpace]
        win.animationBehavior = .none
        win.tabbingMode = .disallowed

        let toolbar = NSToolbar(identifier: "PeekViewer")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        win.toolbar = toolbar

        let container = NSView()
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        win.contentView = container

        let host = NSHostingView(rootView: FilmstripView(m: strip) { [weak self] i in self?.select(i) })
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            host.heightAnchor.constraint(equalToConstant: 84),
        ])
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

    /// Fits the current content into ~80% of the screen at 1:1 pixels or smaller.
    private func idealFrame(on screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        let scale = screen.backingScaleFactor
        let maxW = vf.width * 0.8, maxH = vf.height * 0.88
        let chrome: CGFloat = 52 + (showStrip ? 84 : 0)
        var size = NSSize(width: maxW * 0.75, height: maxH * 0.8)
        if let item, !compare, WebDoc.isWeb(item.urls[index]) || item.urls[index].pathExtension.lowercased() == "pdf" {
            let w: CGFloat = WebDoc.isMarkdown(item.urls[index]) ? 920 : 1240
            size = NSSize(width: w, height: vf.height * 0.86)
        } else if let item, !compare, let px = pixelSize(item.urls[index]) {
            size = NSSize(width: px.width / scale, height: px.height / scale + chrome)
        } else if let item, compare {
            let sizes = item.urls.compactMap(pixelSize)
            let h = sizes.map(\.height).max() ?? 1000
            let w = sizes.reduce(0) { $0 + $1.width * (h / max($1.height, 1)) }
            size = NSSize(width: w / scale + CGFloat(sizes.count + 1) * 16, height: h / scale + chrome)
        }
        let k = min(1, maxW / size.width, maxH / size.height)
        let w = max(560, size.width * k), h = max(400, size.height * k)
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

    // MARK: content

    private func reloadContent(preserving outgoing: NSView? = nil, incomingOffset: CGFloat = 0) {
        guard let item, let win = window, let container = win.contentView else { return }
        win.cancelSwipeTracking()
        if outgoing == nil {
            cancelSwipeAnimation()
            main?.removeFromSuperview()
        } else {
            // The displayed backing store must stay attached throughout the handoff.
            swipeAnimationGeneration += 1
            swipeOffset = 0
        }
        index = min(index, max(0, item.files.count - 1))

        let view: NSView
        if compare {
            let images = item.urls.map { NSImage(contentsOf: $0) ?? NSWorkspace.shared.icon(forFile: $0.path) }
            let host = NSHostingView(rootView: CompareView(images: images))
            host.sizingOptions = []
            view = host
        } else {
            view = Self.makeViewer(for: item.urls[index])
        }
        if outgoing != nil { positionSwipeView(view, at: incomingOffset) }
        container.addSubview(view, positioned: .below, relativeTo: outgoing ?? stripHost)
        if help.visible { toggleHelp() }
        if view is ZoomImageView || compare {
            // Images run under the glass toolbar; ZoomImageView insets itself.
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
        } else if let guide = win.contentLayoutGuide as? NSLayoutGuide {
            // Documents start below the toolbar.
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: guide.topAnchor),
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        main = view

        strip.thumbs = Thumbs.cached(item) ?? []
        strip.names = item.files.map(\.name)
        strip.selected = index
        strip.visible = showStrip
        if let z = view as? ZoomImageView {
            z.topInset = max(28, win.frame.height - win.contentLayoutRect.height)
            z.bottomInset = showStrip ? 84 : 0
        }

        win.title = item.displayTitle
        var sub = item.conversationTitle
        if item.files.count > 1 && !compare { sub += " · \(index + 1)/\(item.files.count)" }
        sub += " · " + RelativeTime.string(item.created, now: Date())
        win.subtitle = sub
        win.toolbar?.items.forEach(refresh)
    }

    static func makeViewer(for url: URL) -> NSView {
        if WebDoc.isWeb(url) { return WebDocView(url: url) }
        let ext = url.pathExtension.lowercased()
        if ext == "pdf", let doc = PDFDocument(url: url) {
            let v = PDFView()
            v.document = doc
            v.autoScales = true
            v.displayMode = .singlePageContinuous
            v.backgroundColor = NSColor(white: 0.075, alpha: 1)
            return v
        }
        if let img = NSImage(contentsOf: url), img.isValid {
            let v = ZoomImageView()
            v.setImage(img)
            return v
        }
        let ql = QLPreviewView(frame: .zero, style: .normal)!
        ql.previewItem = url as NSURL
        return ql
    }

    private func select(_ i: Int) {
        guard let item, i >= 0, i < item.files.count, i != index else { return }
        index = i
        reloadContent()
    }

    func step(_ d: Int) {
        guard let item, !compare, item.files.count > 1 else { return }
        select((index + d + item.files.count) % item.files.count)
    }

    // MARK: interactive swipe animation

    func cancelSwipeAnimation() {
        swipeAnimationGeneration += 1
        swipeOutgoing?.removeFromSuperview()
        swipeOutgoing = nil
        swipeOffset = 0
        if let main, main.layer != nil {
            main.layer?.removeAnimation(forKey: "viewerSwipe")
            positionSwipeView(main, at: 0)
        }
    }

    func updateSwipe(_ offset: CGFloat) {
        guard acceptsSwipeNavigation, !Anim.reduceMotion, let main else { return }
        // Follow small movements directly, with resistance near the window edge.
        let limit = max(1, main.bounds.width * 0.4)
        swipeOffset = limit * CGFloat(tanh(Double(offset / limit)))
        positionSwipeView(main, at: swipeOffset)
    }

    /// Keep selection changes immediate while the outgoing and incoming views slide.
    func finishSwipe(_ direction: Int?) {
        guard let outgoing = main else { return }
        let offset = swipeOffset
        guard let direction, acceptsSwipeNavigation else {
            swipeOffset = 0
            if offset != 0 { animateSwipeView(outgoing, from: offset, to: 0) }
            return
        }
        guard !Anim.reduceMotion, let container = outgoing.superview else {
            step(direction)
            return
        }

        guard let item else { return }
        let destination = container.bounds.width * (direction > 0 ? -1 : 1)
        // Prepare both views and their animations in one render transaction.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        index = (index + direction + item.files.count) % item.files.count
        reloadContent(preserving: outgoing, incomingOffset: offset - destination)
        guard let incoming = main, incoming !== outgoing else { return }
        container.layoutSubtreeIfNeeded()
        positionSwipeView(incoming, at: offset - destination)
        incoming.displayIfNeeded()
        swipeOutgoing = outgoing

        let generation = swipeAnimationGeneration
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.swipeAnimationGeneration == generation else { return }
            self.swipeOutgoing?.removeFromSuperview()
            self.swipeOutgoing = nil
        }
        animateSwipeView(outgoing, from: offset, to: destination)
        animateSwipeView(incoming, from: offset - destination, to: 0)
    }

    private func positionSwipeView(_ view: NSView, at offset: CGFloat) {
        view.wantsLayer = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.transform = CATransform3DMakeTranslation(offset, 0, 0)
        CATransaction.commit()
    }

    private func animateSwipeView(_ view: NSView, from start: CGFloat, to end: CGFloat) {
        positionSwipeView(view, at: end)
        guard !Anim.reduceMotion else { return }
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = start
        animation.toValue = end
        animation.duration = 0.26
        animation.timingFunction = Anim.outQuint
        view.layer?.add(animation, forKey: "viewerSwipe")
    }

    /// Leave horizontal scrolling to an enlarged image; documents still scroll vertically.
    var acceptsSwipeNavigation: Bool {
        guard let item, item.files.count > 1, !compare, !help.visible else { return false }
        if let image = main as? ZoomImageView, let document = image.documentView {
            return document.bounds.width <= image.documentVisibleRect.width + 1
        }
        if let pdf = main as? PDFView, let scroll = pdf.documentView?.enclosingScrollView,
           let document = scroll.documentView {
            return document.bounds.width <= scroll.documentVisibleRect.width + 1
        }
        if let web = main as? WebDocView {
            return web.magnification <= 1 && web.hasHorizontalOverflow == false
        }
        return true
    }

    /// A mouse wheel changes fitted images; documents and enlarged images keep scrolling.
    var acceptsWheelNavigation: Bool {
        guard acceptsSwipeNavigation, let image = main as? ZoomImageView,
              let document = image.documentView else { return false }
        let insets = image.contentInsets
        let visibleHeight = image.documentVisibleRect.height
            - (insets.top + insets.bottom) / max(image.magnification, 0.0001)
        return document.bounds.height <= visibleHeight + 1
    }

    func zoom(_ action: ZoomImageView.Action) {
        window?.cancelSwipeTracking()
        cancelSwipeAnimation()
        (main as? ZoomImageView)?.perform(action)
        (main as? WebDocView)?.zoom(action)
    }

    func toggleCompare() {
        guard let item, item.files.count > 1, let win = window else { return }
        compare.toggle()
        reloadContent()
        let screen = win.screen ?? NSScreen.main ?? NSScreen.screens[0]
        Anim.run(0.32, Anim.outQuint) { win.animator().setFrame(idealFrame(on: screen), display: true) }
    }

    var isKey: Bool { window?.isKeyWindow ?? false }

    func escape() {
        if help.visible { toggleHelp() } else { close() }
    }

    func toggleHelp() {
        window?.cancelSwipeTracking()
        cancelSwipeAnimation()
        withAnimation(.easeOut(duration: 0.16)) { help.visible.toggle() }
        helpHost?.isHidden = !help.visible
    }

    /// ↑ / ↓: the next newer / older card.
    func stepCard(_ d: Int) {
        guard let item else { return }
        app?.openNeighbor(item.id, d)
    }

    func revealCurrent() {
        guard let item else { return }
        app?.reveal(item.id, only: compare ? nil : index)
    }

    /// Close button / ⌘W / ⌘⌫: close the viewer and take the card away.
    func done() {
        guard let item else { return }
        close()
        app?.dismiss(item.id)
    }

    func copyCurrent() {
        guard let item else { return }
        app?.copy(item.id, only: compare ? nil : index)
    }

    // MARK: toolbar

    private enum ID {
        static let nav = NSToolbarItem.Identifier("nav")
        static let compare = NSToolbarItem.Identifier("compare")
        static let copy = NSToolbarItem.Identifier("copy")
        static let reveal = NSToolbarItem.Identifier("reveal")
        static let jump = NSToolbarItem.Identifier("jump")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, ID.nav, ID.compare, ID.copy, ID.reveal, ID.jump]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ID.nav:
            let group = NSToolbarItemGroup(itemIdentifier: id,
                                           images: [symbol("chevron.left"), symbol("chevron.right")],
                                           selectionMode: .momentary, labels: ["上一张 ←", "下一张 →"],
                                           target: self, action: #selector(navTapped(_:)))
            group.label = "切换"
            return group
        case ID.compare:
            return button(id, "rectangle.split.2x1", "并排对比", #selector(compareTapped))
        case ID.copy:
            return button(id, "doc.on.doc", "拷贝  ⌘C", #selector(copyTapped))
        case ID.reveal:
            return button(id, "folder", "在访达中显示  ⌘R", #selector(revealTapped))
        case ID.jump:
            let item = NSToolbarItem(itemIdentifier: id)
            let b = NSButton(title: "回到对话",
                             image: NSImage(systemSymbolName: "arrowshape.turn.up.backward.fill", accessibilityDescription: nil) ?? NSImage(),
                             target: self, action: #selector(jumpTapped))
            b.imagePosition = .imageLeading
            b.imageHugsTitle = true
            b.bezelStyle = .toolbar
            b.font = .systemFont(ofSize: 12.5, weight: .medium)
            item.view = b
            item.label = "回到对话"
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

    private func refresh(_ t: NSToolbarItem) {
        let multi = (item?.files.count ?? 0) > 1
        switch t.itemIdentifier {
        case ID.nav: t.isHidden = !multi || compare
        case ID.compare:
            t.isHidden = !multi
            t.image = NSImage(systemSymbolName: compare ? "square" : "rectangle.split.2x1", accessibilityDescription: nil)
            t.label = compare ? "单张查看  ⌘D" : "并排对比  ⌘D"
            t.toolTip = t.label
        case ID.jump:
            t.isHidden = !(item?.origin?.canJump ?? false)
            if let c = item?.origin?.conversation { t.toolTip = "回到对话  ↩\n\(c)" + (item?.origin?.prompt.map { "\n\($0)" } ?? "") }
        default: break
        }
    }

    @objc private func navTapped(_ sender: NSToolbarItemGroup) { step(sender.selectedIndex == 0 ? -1 : 1) }
    @objc private func compareTapped() { toggleCompare() }
    @objc private func copyTapped() { copyCurrent() }
    @objc private func revealTapped() { revealCurrent() }
    @objc private func jumpTapped() { jumpBack() }

    /// Close the viewer and go back to the conversation; the card stays (read) for a while.
    func jumpBack() {
        guard let item else { return }
        close()
        app?.jump(item.id)
    }
}

final class ViewerWindow: NSPanel {
    weak var viewer: Viewer?

    private enum SwipeAxis { case undecided, horizontal, vertical, discarded }
    private var swipeAxis = SwipeAxis.undecided
    private var swipeX: CGFloat = 0
    private var swipeY: CGFloat = 0
    private var trackingSwipe = false
    private var undecidedScrollEvents: [NSEvent] = []
    private var lastWheelNavigation: (time: TimeInterval, direction: Int)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func resetSwipe(cancelAnimation: Bool = true) {
        trackingSwipe = false
        swipeAxis = .undecided
        swipeX = 0
        swipeY = 0
        undecidedScrollEvents.removeAll()
        lastWheelNavigation = nil
        if cancelAnimation { viewer?.cancelSwipeAnimation() }
    }

    func cancelSwipeTracking() {
        // The buffered prefix never reached a child, so its suffix must not either.
        if trackingSwipe, swipeAxis == .undecided { swipeAxis = .discarded }
        trackingSwipe = false
        undecidedScrollEvents.removeAll()
    }

    // Intercept before NSScrollView, PDFKit or WebKit consumes the scroll event.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .magnify {
            cancelSwipeTracking()
            viewer?.cancelSwipeAnimation()
        }
        if event.type == .scrollWheel, handleWheel(event) || handleSwipe(event) { return }
        super.sendEvent(event)
    }

    private func handleWheel(_ event: NSEvent) -> Bool {
        // Smooth mouse wheels may use pixel deltas too; gesture phases distinguish trackpads.
        guard event.phase.isEmpty, event.momentumPhase.isEmpty,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
              let viewer, viewer.acceptsWheelNavigation else { return false }
        let direction = event.scrollingDeltaY < 0 ? 1 : -1
        // One detent may arrive as a burst; keep quick direction reversals responsive.
        if let last = lastWheelNavigation, last.direction == direction,
           event.timestamp - last.time < 0.2 { return true }
        cancelSwipeTracking()
        viewer.cancelSwipeAnimation()
        viewer.finishSwipe(direction)
        lastWheelNavigation = (event.timestamp, direction)
        return true
    }

    private func handleSwipe(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas else { return false }
        // Momentum belongs to the gesture that just ended, never to a new file.
        if !event.momentumPhase.isEmpty { return swipeAxis == .horizontal || swipeAxis == .discarded }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            // Resting fingers can emit mayBegin while the release animation runs.
            resetSwipe(cancelAnimation: event.phase.contains(.began))
            trackingSwipe = viewer?.acceptsSwipeNavigation ?? false
        }
        guard !event.phase.isEmpty else { return false }
        guard trackingSwipe else { return swipeAxis == .horizontal || swipeAxis == .discarded }

        let fingerX = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        swipeX += fingerX
        swipeY += event.scrollingDeltaY
        if swipeAxis == .undecided, max(abs(swipeX), abs(swipeY)) >= 8 {
            swipeAxis = abs(swipeX) > abs(swipeY) * 1.2 ? .horizontal : .vertical
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
        if swipeAxis == .vertical { undecidedScrollEvents.forEach { super.sendEvent($0) } }
        undecidedScrollEvents.removeAll()
        let consumed = swipeAxis == .horizontal
        if consumed { viewer?.updateSwipe(swipeX) }
        if finished {
            trackingSwipe = false
            if consumed {
                let commit = !event.phase.contains(.cancelled) && abs(swipeX) >= 64
                viewer?.finishSwipe(commit ? (swipeX < 0 ? 1 : -1) : nil)
            }
        }
        return consumed
    }

    override func keyDown(with e: NSEvent) {
        guard let v = viewer else { return super.keyDown(with: e) }
        let m = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let cmd = m == .command
        let plain = m.isEmpty || m == .shift
        switch e.keyCode {
        case 53: v.escape()                                         // esc
        case 49 where plain: v.close()                             // space
        case 13 where cmd: v.done()                                // ⌘W
        case 123 where plain: v.step(-1)                            // ←
        case 124 where plain: v.step(1)                             // →
        case 126 where plain: v.stepCard(-1)                        // ↑ newer card
        case 125 where plain: v.stepCard(1)                         // ↓ older card
        case 36 where m.isEmpty, 76 where m.isEmpty, 36 where cmd: v.jumpBack()   // ↩ back to the conversation
        case 8 where cmd: v.copyCurrent()                           // ⌘C
        case 15 where cmd: v.revealCurrent()                        // ⌘R
        case 2 where cmd: v.toggleCompare()                         // ⌘D
        case 51 where cmd: v.done()                                 // ⌘⌫
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

// MARK: - zoomable image

/// Pinch / ⌘± to zoom, double-click toggles fit ↔ 1:1 pixels, stays centered.
final class ZoomImageView: NSScrollView {
    enum Action { case fit, actual, zoomIn, zoomOut }

    private let imageView = NSImageView()
    private var natural = NSSize.zero
    private var fitting = true
    /// Toolbar above, filmstrip below: the image fits and centers between them.
    var topInset: CGFloat = 52 { didSet { applyInsets() } }
    var bottomInset: CGFloat = 0 { didSet { applyInsets() } }

    private func applyInsets() {
        contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
        if fitting { fit() }
    }

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
        contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = true
        imageView.wantsLayer = true
        imageView.layer?.magnificationFilter = .nearest
        documentView = imageView
        NotificationCenter.default.addObserver(self, selector: #selector(magnified),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: self)
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
        let insets = contentInsets
        let w = bounds.width - insets.left - insets.right - 32
        let h = bounds.height - insets.top - insets.bottom - 24
        guard natural.width > 0, natural.height > 0, w > 0, h > 0 else { return 1 }
        return min(1, w / natural.width, h / natural.height)
    }

    private func fit() { magnification = fitScale }

    func perform(_ action: Action) {
        switch action {
        case .fit: fitting = true; animator().magnification = fitScale
        case .actual: fitting = false; animator().magnification = 1
        case .zoomIn: fitting = false; animator().magnification = min(maxMagnification, magnification * 1.5)
        case .zoomOut: fitting = false; animator().magnification = max(minMagnification, magnification / 1.5)
        }
    }

    @objc private func magnified() { fitting = abs(magnification - fitScale) < 0.01 }

    override func layout() {
        super.layout()
        if fitting { fit() }
    }

    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 {
            let point = imageView.convert(e.locationInWindow, from: nil)
            if fitting || magnification < 0.99 {
                fitting = false
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    animator().setMagnification(1, centeredAt: point)
                }
            } else {
                perform(.fit)
            }
            return
        }
        super.mouseDown(with: e)
    }
}

/// Keeps a smaller-than-viewport document centered instead of pinned bottom-left.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposed)
        guard let doc = documentView, let scroll = superview as? NSScrollView else { return r }
        // Insets are in view points; bounds are in document units (scaled by magnification).
        let m = max(scroll.magnification, 0.0001)
        let top = scroll.contentInsets.top / m, bottom = scroll.contentInsets.bottom / m
        let visibleH = r.height - top - bottom
        if r.width > doc.frame.width { r.origin.x = (doc.frame.width - r.width) / 2 }
        if visibleH > doc.frame.height { r.origin.y = (doc.frame.height - r.height + top - bottom) / 2 }
        return r
    }
}

// MARK: - SwiftUI pieces

final class StripModel: ObservableObject {
    @Published var thumbs: [NSImage] = []
    @Published var names: [String] = []
    @Published var selected = 0
    @Published var visible = false
}

struct FilmstripView: View {
    @ObservedObject var m: StripModel
    var pick: (Int) -> Void

    var body: some View {
        if m.visible {
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
                }
            }
            .padding(8)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .animation(.snappy(duration: 0.22), value: m.selected)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct CompareView: View {
    let images: [NSImage]

    var body: some View {
        HStack(spacing: 16) {
            ForEach(Array(images.enumerated()), id: \.offset) { _, img in
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 60)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - shortcut cheat sheet (?)

final class HelpModel: ObservableObject {
    @Published var visible = false
}

struct ShortcutSheet: View {
    @ObservedObject var m: HelpModel

    private let viewer: [(String, String)] = [
        ("⎋  Space", "关闭"),
        ("←  →", "切换这张卡里的文件"),
        ("双指左右滑", "上一张 / 下一张文件"),
        ("滚轮上下", "上一张 / 下一张图片"),
        ("↑  ↓", "上一张 / 下一张卡"),
        ("↩", "回到对话"),
        ("⌘C", "拷贝"),
        ("⌘R", "在访达中显示"),
        ("⌘D", "并排对比"),
        ("⌘W  ⌘⌫", "关闭并收走这张卡"),
        ("⌘0  ⌘1", "适应窗口 / 原始像素"),
        ("⌘=  ⌘-", "放大 / 缩小"),
    ]

    private var global: [(String, String)] {
        let names: [(Hotkeys.Action, String)] = [(.open, "打开最新一张"), (.tuck, "暂时收起 / 恢复"), (.closeAll, "全部关闭")]
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
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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
