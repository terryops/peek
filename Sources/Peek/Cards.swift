import AppKit
import SwiftUI

enum Anim {
    static let outExpo = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
    static let outQuint = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
    static let inCubic = CAMediaTimingFunction(controlPoints: 0.32, 0, 0.67, 0)
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func run(_ duration: TimeInterval, _ curve: CAMediaTimingFunction,
                    _ changes: () -> Void, done: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = curve
            changes()
        }, completionHandler: done)
    }
}

/// Floats above everything, on every Space, and never takes focus away from
/// whatever you're typing in.
final class CardPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Transparent layer on top of the SwiftUI card that owns every mouse event,
/// so clicks, drags, swipes and hover work while Peek is in the background.
final class CardInteractionView: NSView, NSDraggingSource {
    weak var card: Card?
    private var downEvent: NSEvent?
    private var dragged = false
    private var downOnClose = false

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private func local(_ e: NSEvent) -> NSPoint { convert(e.locationInWindow, from: nil) }
    private func onClose(_ e: NSEvent) -> Bool { card?.closeRect.contains(local(e)) ?? false }

    override func mouseEntered(with e: NSEvent) { card?.setHover(true, close: onClose(e)) }
    override func mouseMoved(with e: NSEvent) { card?.setHover(true, close: onClose(e)) }
    override func mouseExited(with e: NSEvent) { card?.setHover(false, close: false) }

    override func mouseDown(with e: NSEvent) {
        if e.modifierFlags.contains(.control) { return rightMouseDown(with: e) }
        downEvent = e
        dragged = false
        downOnClose = onClose(e) && (card?.model.hovered ?? false)
        if !downOnClose { card?.model.pressed = true }
    }

    override func mouseDragged(with e: NSEvent) {
        guard let down = downEvent, !dragged, !downOnClose, let card else { return }
        let a = down.locationInWindow, b = e.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) > 5 else { return }
        dragged = true
        card.model.pressed = false
        let p = convert(a, from: nil)
        let items: [NSDraggingItem] = card.model.item.urls.enumerated().map { i, url in
            let di = NSDraggingItem(pasteboardWriter: url as NSURL)
            let img = i < card.model.thumbs.count ? card.model.thumbs[i] : NSWorkspace.shared.icon(forFile: url.path)
            let s = img.size, k = 72 / max(s.width, s.height, 1)
            let w = s.width * k, h = s.height * k
            di.setDraggingFrame(NSRect(x: p.x - w / 2 + CGFloat(i) * 5, y: p.y - h / 2 - CGFloat(i) * 5, width: w, height: h),
                                contents: img)
            return di
        }
        guard !items.isEmpty else { return }
        beginDraggingSession(with: items, event: down, source: self)
    }

    override func mouseUp(with e: NSEvent) {
        defer { downEvent = nil }
        card?.model.pressed = false
        guard let card, downEvent != nil, !dragged else { return }
        let p = local(e)
        guard bounds.contains(p) else { return }
        let option = e.modifierFlags.contains(.option)
        if downOnClose && card.closeRect.contains(p) {
            card.close(all: option)
        } else if !downOnClose {
            option ? card.reveal() : card.open()
        }
    }

    override func rightMouseDown(with e: NSEvent) {
        guard let card else { return }
        card.model.pressed = false
        NSMenu.popUpContextMenu(card.contextMenu(), with: e, for: self)
    }

    override func scrollWheel(with e: NSEvent) { card?.scroll(e) }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    // Accessibility: the card is one button; the rest are custom actions.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? {
        guard let item = card?.model.item else { return nil }
        if L10n.isChinese {
            let state = item.seen ? "" : "，未查看"
            return "\(item.displayTitle)，来自\(item.conversationTitle)\(state)"
        } else {
            let state = item.seen ? "" : ", unread"
            return "\(item.displayTitle), from \(item.conversationTitle)\(state)"
        }
    }
    override func accessibilityPerformPress() -> Bool {
        card?.open()
        return true
    }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let card else { return nil }
        var actions = [
            NSAccessibilityCustomAction(name: L10n.tr("关闭", "Close")) { card.close(all: false); return true },
            NSAccessibilityCustomAction(name: L10n.tr("在访达中显示", "Reveal in Finder")) { card.reveal(); return true },
            NSAccessibilityCustomAction(name: L10n.tr("拷贝", "Copy")) { card.copyFiles(); return true },
        ]
        if card.model.item.origin?.canJump ?? false {
            actions.append(NSAccessibilityCustomAction(name: L10n.tr("回到对话", "Jump to Session")) { card.jump(); return true })
        }
        return actions
    }
}

final class Card: NSObject {
    let id: String
    let model: CardModel
    let panel: CardPanel
    weak var stack: CardStack?
    var targetFrame: NSRect = .zero
    /// Ordered in and meant to be visible (false while tucked away).
    var shown = false
    private(set) var swiping = false
    private var swipeX: CGFloat = 0
    private var swipeDecided = false
    private var lingerTimer: Timer?
    private var lastTouched: Date?

    var naturalSize: NSSize { model.size }
    /// Close button only exists on the full card, at its natural size.
    var closeRect: NSRect {
        guard !model.shell else { return .zero }
        let r = CardMetrics.closeRect(model.style, size: model.size)
        // Content is pinned to the top of the window.
        return r.offsetBy(dx: 0, dy: panel.frame.height - model.size.height)
    }

    init(item: PeekItem, thumbs: [NSImage], style: CardStyle, stack: CardStack) {
        id = item.id
        model = CardModel(item: item, thumbs: thumbs, style: style)
        self.stack = stack
        panel = CardPanel(size: model.size)
        super.init()

        let container = NSView(frame: NSRect(origin: .zero, size: model.size))
        let host = NSHostingView(rootView: CardView(m: model))
        host.sizingOptions = []
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        let touch = CardInteractionView(frame: container.bounds)
        touch.autoresizingMask = [.width, .height]
        touch.card = self
        container.addSubview(host)
        container.addSubview(touch)
        panel.contentView = container
        lastTouched = item.lastOpened
        scheduleLinger()
    }

    func update(_ item: PeekItem) {
        if model.item != item { model.item = item }
        if let opened = item.lastOpened, opened > (lastTouched ?? .distantPast) { lastTouched = opened }
        scheduleLinger()
    }

    func teardown() {
        lingerTimer?.invalidate()
        lingerTimer = nil
    }

    // MARK: actions

    func open() {
        // A click on a card tucked behind the front one just fans the deck out.
        if model.shell { stack?.pointerEntered(force: true); return }
        stack?.app?.open(id, from: panel.frame)
    }
    func reveal() { stack?.app?.reveal(id) }
    func copyFiles() { stack?.app?.copy(id) }
    /// From the card itself: back to the conversation, mark read, card goes away.
    func jump() { stack?.app?.jump(id, dismissCard: true) }
    func close(all: Bool) { all ? stack?.app?.dismissAll() : stack?.app?.dismiss(id) }

    func setHover(_ on: Bool, close: Bool) {
        let was = model.hovered
        let on = on && !model.shell
        if was != on { model.hovered = on }
        if model.closeHovered != (close && on) { model.closeHovered = close && on }
        if on || model.shell { stack?.pointerEntered() }
        guard was != on else { return }
        if on {
            lingerTimer?.invalidate()
        } else {
            lastTouched = Date()
            scheduleLinger()
        }
    }

    /// Tracking areas only fire when the mouse moves, not when the card moves
    /// under a still cursor, so re-check after every slide.
    func refreshHover() {
        let p = NSEvent.mouseLocation
        let f = panel.frame
        let inside = shown && panel.isVisible && NSMouseInRect(p, f, false)
        setHover(inside, close: inside && closeRect.contains(NSPoint(x: p.x - f.minX, y: p.y - f.minY)))
    }

    func pulseOnce(after delay: TimeInterval = 0.35) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.model.item.seen else { return }
            self.model.pulse = false
            withAnimation(.easeOut(duration: 1.1)) { self.model.pulse = true }
        }
    }

    func setShell(_ on: Bool) {
        guard model.shell != on else { return }
        if on { setHover(false, close: false) }
        withAnimation(on ? .easeOut(duration: 0.12) : .easeOut(duration: 0.26).delay(0.1)) { model.shell = on }
    }

    // MARK: linger (opened cards leave on their own; unopened ones wait for you)

    var lingerExpired: Bool {
        guard model.item.seen else { return false }
        let since = lastTouched ?? model.item.lastOpened ?? model.item.created
        return Date().timeIntervalSince(since) >= Prefs.linger
    }

    private func scheduleLinger() {
        lingerTimer?.invalidate()
        lingerTimer = nil
        guard model.item.seen, !model.hovered else { return }
        let since = lastTouched ?? model.item.lastOpened ?? Date()
        let wait = max(1, Prefs.linger - Date().timeIntervalSince(since))
        lingerTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            guard let self, !self.model.hovered else { return }
            if Viewer.shared.isShowing(self.id) { self.scheduleLinger(); return }
            self.stack?.app?.dismiss(self.id)
        }
    }

    // MARK: two-finger swipe right to dismiss

    func scroll(_ e: NSEvent) {
        guard e.hasPreciseScrollingDeltas, e.momentumPhase.isEmpty, !model.shell else { return }
        switch e.phase {
        case .began, .mayBegin:
            swiping = true
            swipeDecided = false
            swipeX = 0
            lingerTimer?.invalidate()
        case .changed:
            guard swiping else { return }
            if !swipeDecided {
                if abs(e.scrollingDeltaY) > abs(e.scrollingDeltaX) { swiping = false; return }
                if e.scrollingDeltaX == 0 { return }
                swipeDecided = true
            }
            let fingerDX = e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX
            applySwipe(swipeX + fingerDX)
        case .ended, .cancelled:
            guard swiping else { return }
            endSwipe()
        default:
            break
        }
    }

    func applySwipe(_ x: CGFloat) {
        swiping = true
        swipeX = x
        let shown = x >= 0 ? x : -pow(-x, 0.6)   // resist dragging left
        panel.setFrameOrigin(NSPoint(x: targetFrame.minX + shown, y: targetFrame.minY))
        panel.alphaValue = max(0.2, 1 - max(0, shown) / (targetFrame.width * 0.85))
    }

    func endSwipe() {
        swiping = false
        if swipeX > 64 {
            stack?.app?.dismiss(id)
        } else {
            Anim.run(0.32, Anim.outQuint) {
                panel.animator().setFrame(targetFrame, display: true)
                panel.animator().alphaValue = 1
            }
            scheduleLinger()
        }
        swipeX = 0
    }

    // MARK: context menu

    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, _ hotkey: Hotkeys.Action? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            if let hotkey { Hotkeys.shared.decorate(item, hotkey) }
            menu.addItem(item)
        }
        add(L10n.tr("打开", "Open"), #selector(menuOpen))
        if model.item.origin?.canJump ?? false { add(L10n.tr("回到对话", "Jump to Session"), #selector(menuJump)) }
        add(L10n.tr("在访达中显示", "Reveal in Finder"), #selector(menuReveal))
        add(L10n.tr("拷贝", "Copy"), #selector(menuCopy))
        menu.addItem(.separator())
        add(L10n.tr("暂时收起", "Tuck Aside"), #selector(menuTuck), .tuck)
        add(L10n.tr("关闭", "Close"), #selector(menuClose))
        add(L10n.tr("全部关闭", "Close All"), #selector(menuCloseAll), .closeAll)
        return menu
    }

    @objc private func menuOpen() { open() }
    @objc private func menuJump() { jump() }
    @objc private func menuReveal() { reveal() }
    @objc private func menuCopy() { copyFiles() }
    @objc private func menuClose() { close(all: false) }
    @objc private func menuCloseAll() { close(all: true) }
    @objc private func menuTuck() { stack?.tuck() }
}

/// Lays cards out top-right, newest on top, and animates them in and out.
/// Deck mode keeps older cards tucked under the newest and fans them out on hover.
/// "暂时收起" tucks the whole stack into a handle on the right edge.
final class CardStack {
    enum Mode { case normal, tucked }

    weak var app: App?
    private(set) var cards: [Card] = []
    private(set) var mode: Mode = .normal
    private(set) var peeking = false
    private var leaving: [Card] = []
    private var screen: NSScreen?
    private var loading = Set<String>()
    private let pill = StackPill()
    private let tab = EdgeTab()
    private var stackVisible: Bool { mode == .normal || peeking }
    private var expanded: Bool { Prefs.stacking == .list || stackHovered || peeking }
    private var windowOrder: [Int] = []

    // Stack-level hover: any card, the pill, the handle, and the gaps between them.
    private(set) var stackHovered = false
    private var pollTimer: Timer?
    private var outsideSince: Date?
    private var hoverIntent: DispatchWorkItem?

    init() {
        pill.onClick = { [weak self] in
            guard let self else { return }
            self.mode == .normal ? self.tuck() : self.untuck()
        }
        pill.onHover = { [weak self] on in if on { self?.pointerEntered() } }
        tab.onPeekIntent = { [weak self] in self?.pointerEntered(force: true) }
        tab.onClick = { [weak self] in self?.untuck() }
    }

    /// Brings the on-screen cards in line with the store.
    func sync(_ items: [PeekItem]) {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for card in cards { if let item = byID[card.id] { card.update(item) } }

        let shown = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let candidates = items.filter { item in
            if item.dismissed { return false }
            if !item.seen { return true }
            if let card = shown[item.id] { return !card.lingerExpired }
            guard let opened = item.lastOpened else { return false }
            return Date().timeIntervalSince(opened) < Prefs.linger
        }

        // A card only goes up once its thumbnail is ready, so it never pops in blank.
        var ready: [PeekItem] = []
        for item in candidates {
            if shown[item.id] != nil || Thumbs.cached(item) != nil {
                ready.append(item)
            } else if !loading.contains(item.id) {
                loading.insert(item.id)
                Thumbs.load(item) { [weak self] _ in
                    self?.loading.remove(item.id)
                    self?.app?.refresh()
                }
            }
        }

        let maxCards = Prefs.maxCards
        let wanted = Array(ready.prefix(maxCards))
        // Opened cards pushed off by newer ones don't come back; unopened ones wait their turn.
        for item in ready.dropFirst(maxCards) where item.seen { app?.markDismissed(item.id) }

        let wantedIDs = Set(wanted.map(\.id))
        for card in cards where !wantedIDs.contains(card.id) { animateOut(card) }

        var next: [Card] = []
        var fresh = Set<String>()
        let style = Prefs.style
        for item in wanted {
            if let card = shown[item.id] {
                next.append(card)
            } else {
                if cards.isEmpty && next.isEmpty { screen = nil }
                next.append(Card(item: item, thumbs: Thumbs.cached(item) ?? [], style: style, stack: self))
                fresh.insert(item.id)
            }
        }
        let changed = next.map(\.id) != cards.map(\.id)
        cards = next
        if cards.isEmpty {
            // Nothing left to tuck away: the next card shows normally again.
            mode = .normal
            peeking = false
            tab.hide()
            pill.hide()
            stopPolling()
            stackHovered = false
            screen = nil
            return
        }
        if changed || !fresh.isEmpty { layout(fresh: fresh) }
        if !fresh.isEmpty && !stackVisible { tab.bump() }
        updateControls()
    }

    func relayout() {
        if let s = screen, !NSScreen.screens.contains(s) { screen = nil }
        layout(fresh: [])
        updateControls()
    }

    /// Style changed: rebuild every card in the new look.
    func restyle() {
        for card in cards {
            card.teardown()
            card.panel.orderOut(nil)
        }
        cards = []
        windowOrder = []
        app?.refresh()
    }

    // MARK: tuck / peek

    func tuck() {
        guard mode == .normal, !cards.isEmpty else { return }
        mode = .tucked
        peeking = false
        pill.hide()
        for (i, card) in cards.enumerated() { slideOut(card, delay: Double(i) * 0.03) }
        if let s = currentScreen() { tab.place(on: s) }
        updateTab()
        tab.show(delay: 0.12)
        // The mouse is probably still where the cards were; don't bounce them right back.
        stopPolling()
        stackHovered = false
    }

    func untuck() {
        guard mode == .tucked else { return }
        mode = .normal
        let wasPeeking = peeking
        peeking = false
        tab.hide()
        if !wasPeeking { layout(fresh: []) }
        updateControls()
    }

    private func peek() {
        guard mode == .tucked, !peeking, !cards.isEmpty else { return }
        peeking = true
        tab.hide()
        layout(fresh: [])
        updateControls()
    }

    private func unpeek() {
        guard peeking else { return }
        peeking = false
        pill.hide()
        for (i, card) in cards.enumerated().reversed() { slideOut(card, delay: Double(cards.count - 1 - i) * 0.025) }
        updateTab()
        tab.show(delay: 0.1)
    }

    // MARK: hover across the whole stack

    /// `force` skips the short hover-intent delay (the handle has its own; debug uses it too).
    func pointerEntered(force: Bool = false) {
        outsideSince = nil
        startPolling()
        guard !stackHovered else { return }
        if force {
            hoverIntent?.cancel()
            hoverIntent = nil
            stackHovered = true
            hoverChanged()
            return
        }
        guard hoverIntent == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverIntent = nil
            guard !self.stackHovered, self.hoverRegion().contains(NSEvent.mouseLocation) else { return }
            self.stackHovered = true
            self.hoverChanged()
        }
        hoverIntent = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        let t = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func poll() {
        if hoverRegion().contains(NSEvent.mouseLocation) {
            outsideSince = nil
            return
        }
        let now = Date()
        guard let since = outsideSince else { outsideSince = now; return }
        if now.timeIntervalSince(since) >= (peeking ? 0.35 : 0.25) {
            stopPolling()
            hoverIntent?.cancel()
            hoverIntent = nil
            if stackHovered {
                stackHovered = false
                hoverChanged()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        outsideSince = nil
    }

    private func hoverRegion() -> NSRect {
        var r = NSRect.null
        if stackVisible { for card in cards where card.shown { r = r.union(card.targetFrame) } }
        if pill.isShown { r = r.union(pill.target) }
        if mode == .tucked { r = r.union(tab.target) }
        return r.isNull ? .zero : r.insetBy(dx: -10, dy: -10)
    }

    private func hoverChanged() {
        if mode == .tucked {
            if stackHovered && !peeking { peek() } else if !stackHovered && peeking { unpeek() }
        } else if Prefs.stacking == .deck && cards.count > 1 {
            layout(fresh: [])
        }
        updateControls()
    }

    private func updateControls() {
        updateTab()
        if stackHovered && stackVisible && expanded, let last = cards.last {
            pill.show(tucked: mode == .tucked, below: last.targetFrame)
        } else {
            pill.hide()
        }
    }

    private func updateTab() {
        guard let first = cards.first else { return }
        let unread = cards.filter { !$0.model.item.seen }.count
        tab.update(thumb: first.model.thumbs.first, count: cards.count, unread: unread)
    }

    // MARK: layout

    private func currentScreen() -> NSScreen? {
        if let screen, NSScreen.screens.contains(screen) { return screen }
        let mouse = NSEvent.mouseLocation
        let s = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
        screen = s
        return s
    }

    /// Where every card goes: a column when expanded, a deck (front card + slivers) otherwise.
    private func frames(on screen: NSScreen) -> [(frame: NSRect, shell: Bool)] {
        let vf = screen.visibleFrame
        let right = vf.maxX - CardMetrics.edge
        var top = vf.maxY - CardMetrics.top
        if expanded {
            return cards.map { card in
                let s = card.naturalSize
                let f = NSRect(x: right - s.width, y: top - s.height, width: s.width, height: s.height).integral
                top = f.minY - CardMetrics.gap
                return (f, false)
            }
        }
        let s0 = cards[0].naturalSize
        let front = NSRect(x: right - s0.width, y: top - s0.height, width: s0.width, height: s0.height).integral
        return cards.enumerated().map { i, _ in
            guard i > 0 else { return (front, false) }
            let d = CGFloat(min(i, 2))
            let w = s0.width - 22 * d
            let h = min(s0.height - 10 * d, 46)
            let f = NSRect(x: front.midX - w / 2, y: front.minY - 9 * d, width: w, height: h).integral
            return (f, true)
        }
    }

    private func layout(fresh: Set<String>) {
        guard !cards.isEmpty, let screen = currentScreen() else { return }
        tab.place(on: screen)
        let targets = frames(on: screen)
        for (i, card) in cards.enumerated() {
            let t = targets[i]
            card.targetFrame = t.frame
            card.model.depth = i
            guard stackVisible else { continue }
            card.setShell(t.shell)
            if !card.shown {
                let isNew = fresh.contains(card.id)
                slideIn(card, delay: isNew ? 0 : Double(i) * 0.035, slow: isNew)
                if isNew { card.pulseOnce() }
            } else if !card.swiping && card.panel.frame != t.frame {
                Anim.run(Anim.reduceMotion ? 0.2 : 0.42, Anim.outQuint, {
                    card.panel.animator().setFrame(t.frame, display: true)
                }, done: {
                    card.panel.invalidateShadow()
                    card.refreshHover()
                })
            }
        }
        orderWindows()
    }

    /// Front card on top of the slivers behind it.
    private func orderWindows() {
        let order = cards.map { $0.panel.windowNumber }
        guard order != windowOrder else { return }
        windowOrder = order
        for card in cards.reversed() where card.shown { card.panel.orderFrontRegardless() }
    }

    private func slideIn(_ card: Card, delay: TimeInterval, slow: Bool) {
        card.shown = true
        card.model.shown = true
        windowOrder = []
        let f = card.targetFrame
        let reduce = Anim.reduceMotion
        card.panel.setFrame(reduce ? f : f.offsetBy(dx: slow ? 30 : 44, dy: 0), display: false)
        card.panel.alphaValue = 0
        card.panel.orderFrontRegardless()
        card.panel.invalidateShadow()
        let go = {
            guard card.shown else { return }
            Anim.run(reduce ? 0.2 : (slow ? 0.55 : 0.42), Anim.outExpo, {
                card.panel.animator().setFrame(card.targetFrame, display: true)
                card.panel.animator().alphaValue = 1
            }, done: {
                card.panel.invalidateShadow()
                card.refreshHover()
            })
        }
        delay > 0 ? DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: go) : go()
    }

    /// Hide without removing (tucked away); the card keeps its state.
    private func slideOut(_ card: Card, delay: TimeInterval) {
        guard card.shown else { return }
        card.shown = false
        card.model.shown = false
        card.setHover(false, close: false)
        let go = {
            guard !card.shown else { return }
            let end = Anim.reduceMotion ? card.targetFrame : card.targetFrame.offsetBy(dx: 56, dy: 0)
            Anim.run(0.2, Anim.inCubic, {
                card.panel.animator().setFrame(end, display: true)
                card.panel.animator().alphaValue = 0
            }, done: {
                if !card.shown { card.panel.orderOut(nil) }
            })
        }
        delay > 0 ? DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: go) : go()
    }

    private func animateOut(_ card: Card) {
        card.teardown()
        guard card.shown else {
            card.model.shown = false
            card.panel.orderOut(nil)
            return
        }
        card.shown = false
        card.model.shown = false
        leaving.append(card)
        let reduce = Anim.reduceMotion
        let end = reduce ? card.panel.frame : card.panel.frame.offsetBy(dx: 40, dy: 0)
        Anim.run(reduce ? 0.18 : 0.24, Anim.inCubic, {
            card.panel.animator().setFrame(end, display: true)
            card.panel.animator().alphaValue = 0
        }, done: { [weak self] in
            card.panel.orderOut(nil)
            self?.leaving.removeAll { $0 === card }
        })
    }

    // MARK: debug

    func snapshot() -> [String: Any] {
        [
            "mode": mode == .normal ? "normal" : "tucked",
            "style": Prefs.style.rawValue,
            "stacking": Prefs.stacking.rawValue,
            "peeking": peeking,
            "stackHovered": stackHovered,
            "pill": pill.isShown ? "\(StackPill.title(tucked: pill.model.tucked)) \(NSStringFromRect(pill.panel.frame))" : "-",
            "tab": tab.isShown ? "\(tab.model.unread)/\(tab.model.count) \(NSStringFromRect(tab.panel.frame)) a=\(tab.panel.alphaValue)" : "-",
            "tabWindow": tab.panel.windowNumber,
            "pillWindow": pill.panel.windowNumber,
            "list": cards.map { c in
                [
                    "id": c.id,
                    "window": c.panel.windowNumber,
                    "frame": NSStringFromRect(c.panel.frame),
                    "alpha": c.panel.alphaValue,
                    "shown": c.shown,
                    "shell": c.model.shell,
                    "seen": c.model.item.seen,
                    "hovered": c.model.hovered,
                    "thumbs": c.model.thumbs.count,
                    "title": c.model.item.displayTitle,
                    "conversation": c.model.item.conversationTitle,
                ] as [String: Any]
            },
        ]
    }
}
