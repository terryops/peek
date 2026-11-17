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
    private let compareZoom = CompareZoomModel()
    private var swipeOffset: CGFloat = 0
    private var swipeOutgoing: NSView?
    private var swipeAnimationGeneration = 0
    private static let sidebarWidth: CGFloat = 172
    private static let sidebarBreakpoint: CGFloat = 760

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
            "navigation": showStrip ? (strip.sidebar ? "sidebar" : "filmstrip") : "none",
            "file": item?.files[index].name ?? "",
            "help": help.visible,
            "item": item?.displayTitle ?? "",
            "key": win.isKeyWindow,
            "appActive": NSApp.isActive,
            "content": main.map { String(describing: type(of: $0)) } ?? "-",
            "magnification": (main as? ZoomImageView)?.magnification ?? 0,
            "swipeOffset": swipeOffset,
            "toolbar": win.toolbar?.items.filter { isToolbarItemVisible($0) }.map(\.label) ?? [],
        ]
    }

    // MARK: open / close

    func show(_ item: PeekItem, from origin: NSRect?, selectedIndex: Int? = nil) {
        guard !item.files.isEmpty else { return }
        let reopenSame = isOpen && self.item?.id == item.id
        self.item = item
        let screen = origin.flatMap { r in NSScreen.screens.first { $0.frame.intersects(r) } } ?? NSScreen.main ?? NSScreen.screens[0]
        if !reopenSame {
            index = 0
            compare = false
        }
        if let selectedIndex {
            index = min(max(0, selectedIndex), item.files.count - 1)
            compare = false
        }

        let win = window ?? makeWindow()
        win.resetSwipe()
        let target = idealFrame(on: screen)
        reloadContent()

        // A non-activating panel: it takes the keyboard (esc, arrows, ⌘C) while the app
        // you were in stays active, so closing it drops you right back where you were.
        defer { syncToolbar(win.toolbar) }
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

    /// Fits the current content into ~80% of the screen at 1:1 pixels or smaller.
    private func idealFrame(on screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        let scale = screen.backingScaleFactor
        let maxW = vf.width * 0.8, maxH = vf.height * 0.88
        let sidebar = showStrip && maxW >= Self.sidebarBreakpoint
        let chrome: CGFloat = 52 + (showStrip && !sidebar ? 84 : 0)
        var size = NSSize(width: maxW * 0.75, height: maxH * 0.8)
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
        let k = min(1, maxW / size.width, maxH / size.height)
        let w = max(sidebar ? min(800, maxW) : 560, size.width * k)
        let h = max(sidebar ? min(520, maxH) : 400, size.height * k)
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

    /// The sidebar and detail share a boundary; documents never run beneath navigation.
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
        for view in [main, swipeOutgoing].compactMap({ $0 }) {
            let image = view as? ZoomImageView
            view.frame = NSRect(x: left, y: image != nil || compare ? 0 : bottom,
                                width: max(0, bounds.width - left),
                                height: image != nil || compare ? bounds.height : max(0, contentHeight - bottom))
            if let image {
                image.topInset = max(28, bounds.height - contentHeight)
                image.bottomInset = bottom
            }
        }
    }

    func isOverNavigation(_ event: NSEvent) -> Bool {
        guard showStrip, let host = stripHost, let container = window?.contentView else { return false }
        return host.frame.contains(container.convert(event.locationInWindow, from: nil))
    }

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
            compareZoom.reset()
            let images = item.urls.map { NSImage(contentsOf: $0) ?? NSWorkspace.shared.icon(forFile: $0.path) }
            let host = NSHostingView(rootView: CompareView(images: images, names: item.files.map(\.name), zoom: compareZoom,
                                                         pick: { [weak self] i in self?.select(i) }))
            host.sizingOptions = []
            view = host
        } else {
            view = Self.makeViewer(for: item.urls[index])
        }
        if outgoing != nil { positionSwipeView(view, at: incomingOffset) }
        container.addSubview(view, positioned: .below, relativeTo: outgoing ?? stripHost)
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
        guard let ql = QLPreviewView(frame: .zero, style: .normal) else { return NSView() }
        ql.previewItem = url as NSURL
        return ql
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
        let destination = outgoing.bounds.width * (direction > 0 ? -1 : 1)
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
        if compare {
            compareZoom.perform(action)
            return
        }
        (main as? ZoomImageView)?.perform(action)
        (main as? WebDocView)?.zoom(action)
    }

    func toggleCompare() {
        guard let item, item.files.count > 1, item.allImages, let win = window else { return }
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

    /// ↑ / ↓ follows the visible file list; single-file cards still walk history.
    func stepVertical(_ d: Int) {
        if (item?.files.count ?? 0) > 1 { step(d) } else { stepCard(d) }
    }

    /// ⌥↑ / ⌥↓: the next newer / older card.
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
            let group = NSToolbarItemGroup(
                itemIdentifier: id,
                images: [symbol("chevron.left"), symbol("chevron.right")],
                selectionMode: .momentary,
                labels: [L10n.tr("上一张 ←", "Previous ←"), L10n.tr("下一张 →", "Next →")],
                target: self, action: #selector(navTapped(_:))
            )
            group.label = L10n.tr("切换", "Navigate")
            return group
        case ID.compare:
            return button(id, "rectangle.split.2x1", L10n.tr("并排对比", "Compare"), #selector(compareTapped))
        case ID.copy:
            return button(id, "doc.on.doc", L10n.tr("拷贝  ⌘C", "Copy  ⌘C"), #selector(copyTapped))
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
            if multi && item?.allImages == true { wanted.append(ID.compare) }
            wanted.append(contentsOf: [ID.copy, ID.reveal])
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
        case ID.compare:
            setToolbarItemHidden(t, !multi || item?.allImages != true)
            t.image = NSImage(systemSymbolName: compare ? "square" : "rectangle.split.2x1", accessibilityDescription: nil)
            t.label = compare
                ? L10n.tr("单张查看  ⌘D", "Single View  ⌘D")
                : L10n.tr("并排对比  ⌘D", "Compare  ⌘D")
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
        // WebKit and SwiftUI can otherwise consume arrows before the window sees them.
        if event.type == .keyDown, [123, 124, 125, 126].contains(event.keyCode),
           event.modifierFlags.intersection([.command, .control]).isEmpty {
            keyDown(with: event)
            return
        }
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
              let viewer, !viewer.isOverNavigation(event), viewer.acceptsWheelNavigation else { return false }
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
            trackingSwipe = (viewer?.acceptsSwipeNavigation ?? false) && !(viewer?.isOverNavigation(event) ?? false)
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
        case 126 where plain: v.stepVertical(-1)                    // ↑ previous file
        case 125 where plain: v.stepVertical(1)                     // ↓ next file
        case 126 where m == .option: v.stepCard(-1)                 // ⌥↑ newer card
        case 125 where m == .option: v.stepCard(1)                  // ⌥↓ older card
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

private final class ViewerContentView: NSView {
    var onResize: (() -> Void)?

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        onResize?()
    }
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
            let baseH = max(1, geo.size.height - 76)
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
                .padding(.horizontal, 16)
                .padding(.top, 60)
                .padding(.bottom, 16)
                .frame(width: baseW * s + 32, height: baseH * s + 76)
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
}

struct ShortcutSheet: View {
    @ObservedObject var m: HelpModel

    private var viewer: [(String, String)] {
        [
            ("⎋  Space", L10n.tr("关闭", "Close")),
            ("←  →", L10n.tr("切换这张卡里的文件", "Previous / next file")),
            (L10n.tr("双指左右滑", "Swipe ↔"), L10n.tr("上一张 / 下一张文件", "Previous / next file")),
            (L10n.tr("滚轮上下", "Scroll ↕"), L10n.tr("上一张 / 下一张图片", "Previous / next image")),
            ("↑  ↓", L10n.tr("切换文件（单文件时切换卡片）", "Files (cards for single files)")),
            ("⌥↑  ⌥↓", L10n.tr("上一张 / 下一张卡", "Newer / older card")),
            ("↩", L10n.tr("回到对话", "Jump to session")),
            ("⌘C", L10n.tr("拷贝", "Copy")),
            ("⌘R", L10n.tr("在访达中显示", "Reveal in Finder")),
            ("⌘D", L10n.tr("并排对比", "Side-by-side compare")),
            ("⌘W  ⌘⌫", L10n.tr("关闭并收走这张卡", "Close & dismiss card")),
            ("⌘0  ⌘1", L10n.tr("适应窗口 / 原始像素", "Fit to window / 1:1 pixels")),
            ("⌘=  ⌘-", L10n.tr("放大 / 缩小", "Zoom in / out")),
        ]
    }

    private var global: [(String, String)] {
        let names: [(Hotkeys.Action, String)] = [
            (.open, L10n.tr("打开最新一张", "Open newest card")),
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
