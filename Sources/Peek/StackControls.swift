import AppKit
import SwiftUI

/// Mouse handling for the small controls (pill under the stack, edge handle).
final class ControlInteractionView: NSView {
    var onHover: ((Bool) -> Void)?
    var onPress: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    var label = ""

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with e: NSEvent) { onHover?(true) }
    override func mouseExited(with e: NSEvent) { onHover?(false) }
    override func mouseDown(with e: NSEvent) { onPress?(true) }
    override func mouseUp(with e: NSEvent) {
        onPress?(false)
        if bounds.contains(convert(e.locationInWindow, from: nil)) { onClick?() }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { label }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

private func makePanel<V: View>(_ view: V, size: NSSize) -> (CardPanel, ControlInteractionView) {
    let panel = CardPanel(size: size)
    let container = NSView(frame: NSRect(origin: .zero, size: size))
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    host.frame = container.bounds
    host.autoresizingMask = [.width, .height]
    let touch = ControlInteractionView(frame: container.bounds)
    touch.autoresizingMask = [.width, .height]
    container.addSubview(host)
    container.addSubview(touch)
    panel.contentView = container
    return (panel, touch)
}

// MARK: pill under the stack: 暂时收起 / 保持展开

final class PillModel: ObservableObject {
    @Published var tucked = false
    @Published var hovered = false
    @Published var pressed = false
}

struct PillView: View {
    @ObservedObject var m: PillModel

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: m.tucked ? "pin.fill" : "arrow.right.to.line")
                .font(.system(size: 10, weight: .semibold))
            Text(StackPill.title(tucked: m.tucked))
                .font(StackPill.swiftUIFont)
        }
        .foregroundStyle(m.hovered ? .primary : .secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule().fill(Color.primary.opacity(m.hovered ? 0.07 : 0)))
        .peekGlass(in: Capsule())
        .scaleEffect(m.pressed ? 0.95 : 1)
        .animation(.easeOut(duration: 0.12), value: m.hovered)
        .animation(.spring(response: 0.24, dampingFraction: 0.7), value: m.pressed)
    }
}

final class StackPill {
    static let height: CGFloat = 26
    static let fontSize: CGFloat = 11.5
    static var swiftUIFont: Font { .system(size: fontSize, weight: .medium) }
    static func title(tucked: Bool) -> String {
        tucked ? L10n.tr("保持展开", "Keep Open") : L10n.tr("暂时收起", "Tuck Aside")
    }

    let model = PillModel()
    let panel: CardPanel
    private let touch: ControlInteractionView
    private(set) var isShown = false
    private(set) var target: NSRect = .zero
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    init() {
        (panel, touch) = makePanel(PillView(m: model), size: NSSize(width: 100, height: Self.height))
        touch.onHover = { [weak self] on in
            self?.model.hovered = on
            self?.onHover?(on)
        }
        touch.onPress = { [weak self] on in self?.model.pressed = on }
        touch.onClick = { [weak self] in self?.onClick?() }
    }

    private static func width(tucked: Bool) -> CGFloat {
        let text = title(tucked: tucked) as NSString
        let w = text.size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium)]).width
        return ceil(w + 12 + 5 + 24)
    }

    /// Sits right-aligned just under `anchor` (the bottom card).
    func show(tucked: Bool, below anchor: NSRect) {
        model.tucked = tucked
        touch.label = Self.title(tucked: tucked)
        let w = Self.width(tucked: tucked)
        let f = NSRect(x: anchor.maxX - w, y: anchor.minY - CardMetrics.gap - Self.height, width: w, height: Self.height).integral
        target = f
        if isShown {
            if panel.frame != f { Anim.run(0.3, Anim.outQuint) { panel.animator().setFrame(f, display: true) } }
            return
        }
        isShown = true
        panel.setFrame(f.offsetBy(dx: 0, dy: 5), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        Anim.run(0.22, Anim.outExpo) {
            panel.animator().setFrame(f, display: true)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        model.hovered = false
        Anim.run(0.14, Anim.inCubic, { panel.animator().alphaValue = 0 }, done: { [weak self] in
            guard let self, !self.isShown else { return }
            self.panel.orderOut(nil)
        })
    }
}

// MARK: handle on the right edge while the stack is tucked away

final class TabModel: ObservableObject {
    @Published var thumb: NSImage?
    @Published var count = 0
    @Published var unread = 0
    @Published var hovered = false
    @Published var bump = false
}

struct TabView: View {
    @ObservedObject var m: TabModel
    private let shape = UnevenRoundedRectangle(topLeadingRadius: 13, bottomLeadingRadius: 13,
                                               bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let img = m.thumb {
                    Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                } else {
                    Color.primary.opacity(0.1)
                }
            }
            .frame(width: 16, height: 16)
            .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4.5, style: .continuous).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            Text("\(m.unread > 0 ? m.unread : m.count)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(m.unread > 0 ? Color(nsColor: .controlAccentColor) : .secondary)
                .contentTransition(.numericText())
        }
        .offset(x: 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(Color.primary.opacity(m.hovered ? 0.07 : 0)))
        .peekGlass(in: shape)
        .scaleEffect(m.bump ? 1.12 : 1, anchor: .trailing)
        .animation(.easeOut(duration: 0.12), value: m.hovered)
        .animation(.spring(response: 0.3, dampingFraction: 0.5), value: m.bump)
        .animation(.snappy, value: m.count)
        .animation(.snappy, value: m.unread)
    }
}

final class EdgeTab {
    static let size = NSSize(width: 26, height: 62)
    let model = TabModel()
    let panel: CardPanel
    private let touch: ControlInteractionView
    private(set) var isShown = false
    private(set) var target: NSRect = .zero
    private var intent: DispatchWorkItem?
    /// Hovered long enough to mean it (so brushing past the screen edge doesn't expand anything).
    var onPeekIntent: (() -> Void)?
    var onClick: (() -> Void)?

    init() {
        (panel, touch) = makePanel(TabView(m: model), size: Self.size)
        touch.onHover = { [weak self] on in self?.hover(on) }
        touch.onClick = { [weak self] in self?.onClick?() }
    }

    private func hover(_ on: Bool) {
        model.hovered = on
        intent?.cancel()
        guard on else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.hovered, self.isShown else { return }
            self.onPeekIntent?()
        }
        intent = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    func place(on screen: NSScreen) {
        let vf = screen.visibleFrame
        target = NSRect(x: vf.maxX - Self.size.width, y: vf.maxY - CardMetrics.top - Self.size.height,
                        width: Self.size.width, height: Self.size.height).integral
        if isShown && panel.frame != target { panel.setFrame(target, display: true) }
    }

    func update(thumb: NSImage?, count: Int, unread: Int) {
        if model.thumb !== thumb { model.thumb = thumb }
        if model.count != count { model.count = count }
        if model.unread != unread { model.unread = unread }
        touch.label = unread > 0
            ? L10n.tr("已收起，\(unread) 张未查看，展开", "Tucked, \(unread) unread, expand")
            : L10n.tr("已收起 \(count) 张卡片，展开", "Tucked \(count) cards, expand")
    }

    func show(delay: TimeInterval = 0.1) {
        guard !isShown else { return }
        isShown = true
        model.hovered = false
        panel.setFrame(target.offsetBy(dx: Self.size.width, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isShown else { return }
            Anim.run(0.4, Anim.outExpo) {
                self.panel.animator().setFrame(self.target, display: true)
                self.panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        intent?.cancel()
        Anim.run(0.16, Anim.inCubic, {
            panel.animator().setFrame(target.offsetBy(dx: Self.size.width * 0.6, dy: 0), display: true)
            panel.animator().alphaValue = 0
        }, done: { [weak self] in
            guard let self, !self.isShown else { return }
            self.panel.orderOut(nil)
        })
    }

    func bump() {
        model.bump = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in self?.model.bump = false }
    }
}
