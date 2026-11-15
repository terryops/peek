import AppKit
import SwiftUI

enum CardStyle: String, CaseIterable {
    case compact, rich, photo
    var label: String {
        switch self {
        case .compact: L10n.tr("简洁", "Compact")
        case .rich: L10n.tr("大图", "Rich")
        case .photo: L10n.tr("照片", "Photo")
        }
    }
}

enum StackMode: String { case deck, list }

enum Prefs {
    /// How long a card stays after you've opened it (hovering resets the clock).
    static var linger: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "lingerSeconds")
        return v > 0 ? v : 300
    }
    static var maxCards: Int {
        let v = UserDefaults.standard.integer(forKey: "maxCards")
        return v > 0 ? v : 3
    }
    static var style: CardStyle {
        get { CardStyle(rawValue: UserDefaults.standard.string(forKey: "style") ?? "") ?? .rich }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "style") }
    }
    /// deck: newest on top, older ones peek out underneath and fan out on hover.
    static var stacking: StackMode {
        get { StackMode(rawValue: UserDefaults.standard.string(forKey: "stacking") ?? "") ?? .deck }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "stacking") }
    }
}

enum CardMetrics {
    static let gap: CGFloat = 10
    /// Distance from the screen's right edge / from the menu bar.
    static let edge: CGFloat = 12
    static let top: CGFloat = 8

    static func size(_ style: CardStyle, thumbs: [NSImage]) -> NSSize {
        switch style {
        case .compact: return NSSize(width: 340, height: 80)
        case .rich: return NSSize(width: 340, height: 238)
        case .photo:
            let s = thumbs.first?.size ?? NSSize(width: 16, height: 10)
            let aspect = s.height > 0 ? s.width / s.height : 1.6
            return NSSize(width: 260, height: min(330, max(150, (260 / aspect).rounded())))
        }
    }

    static func radius(_ style: CardStyle) -> CGFloat {
        switch style {
        case .compact: 20
        case .rich: 24
        case .photo: 20
        }
    }

    /// Hit area for the close button, in the card's (unflipped) coordinates.
    static func closeRect(_ style: CardStyle, size: NSSize) -> NSRect {
        switch style {
        case .compact: NSRect(x: size.width - 44, y: size.height - 40, width: 34, height: 32)
        case .rich: NSRect(x: size.width - 46, y: size.height - 42, width: 36, height: 34)
        case .photo: NSRect(x: 4, y: size.height - 40, width: 36, height: 36)
        }
    }
}

final class CardModel: ObservableObject {
    @Published var item: PeekItem
    @Published var thumbs: [NSImage]
    let style: CardStyle
    let size: NSSize
    @Published var hovered = false
    @Published var closeHovered = false
    @Published var pressed = false
    @Published var pulse = false
    /// Tucked behind the front card in the deck: just the plate, no content.
    @Published var shell = false
    @Published var shown = false
    @Published var depth = 0

    init(item: PeekItem, thumbs: [NSImage], style: CardStyle) {
        self.item = item
        self.thumbs = thumbs
        self.style = style
        self.size = CardMetrics.size(style, thumbs: thumbs)
    }

    var countText: String? {
        let n = item.files.count
        guard n > 1 else { return nil }
        return item.allImages
            ? L10n.tr("\(n) 张", "\(n) images")
            : L10n.tr("\(n) 个文件", "\(n) files")
    }
}

struct CardView: View {
    @ObservedObject var m: CardModel

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CardMetrics.radius(m.style), style: .continuous)
        // The plate always matches the window (it shrinks to a sliver in the deck);
        // the content keeps its natural size and is only laid over it.
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if m.style != .photo || m.shell {
                    Color.clear
                        .peekGlass(in: shape)
                        .overlay(shape.fill(Color.primary.opacity(m.hovered && !m.shell ? 0.05 : 0)))
                        .overlay(shape.fill(Color.black.opacity(m.shell ? 0.05 * Double(m.depth) : 0)))
                }
            }
            .overlay(alignment: .top) {
                content
                    .frame(width: m.size.width, height: m.size.height)
                    .opacity(m.shell ? 0 : 1)
            }
            .scaleEffect(m.pressed ? 0.975 : 1)
        .animation(.spring(response: 0.26, dampingFraction: 0.7), value: m.pressed)
        .animation(.easeOut(duration: 0.16), value: m.hovered)
        .animation(.easeOut(duration: 0.12), value: m.closeHovered)
        .animation(.easeInOut(duration: 0.3), value: m.item.seen)
    }

    @ViewBuilder private var content: some View {
        switch m.style {
        case .compact: CompactCard(m: m)
        case .rich: RichCard(m: m)
        case .photo: PhotoCard(m: m)
        }
    }
}

// MARK: styles

/// 简洁: one row, thumbnail + three short lines.
struct CompactCard: View {
    @ObservedObject var m: CardModel

    var body: some View {
        HStack(spacing: 12) {
            ThumbStack(images: m.thumbs, count: m.item.files.count, side: 58, radius: 12)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    ConversationLabel(text: m.item.conversationTitle)
                    Spacer(minLength: 4)
                    TimeOrClose(m: m)
                }
                HStack(spacing: 6) {
                    if !m.item.seen { UnreadDot(pulse: m.pulse, size: 7) }
                    Text(m.item.displayTitle)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(meta)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 14)
    }

    private var meta: String {
        var parts: [String] = []
        if m.item.conversationTitle != m.item.source { parts.append(m.item.source) }
        if let c = m.countText { parts.append(c) }
        return parts.isEmpty ? (m.item.files.first?.name ?? "") : parts.joined(separator: " · ")
    }
}

/// 大图: header like a notification, then the whole screenshot over a blur of itself.
struct RichCard: View {
    @ObservedObject var m: CardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    ConversationLabel(text: m.item.conversationTitle)
                    HStack(spacing: 6) {
                        if !m.item.seen { UnreadDot(pulse: m.pulse, size: 7) }
                        Text(m.item.displayTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let c = m.countText {
                            Text(c).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize()
                        }
                    }
                }
                Spacer(minLength: 4)
                TimeOrClose(m: m)
            }
            .padding(.horizontal, 5)
            PreviewPane(images: m.thumbs, count: m.item.files.count)
                .frame(height: 172)
        }
        .padding(11)
    }
}

/// 照片: the image is the card; title on a soft gradient.
struct PhotoCard: View {
    @ObservedObject var m: CardModel
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: CardMetrics.radius(.photo), style: .continuous) }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
                .overlay(alignment: .top) {
                    if let img = m.thumbs.first {
                        Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    }
                }
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.18), .black.opacity(0.66)],
                           startPoint: UnitPoint(x: 0.5, y: 0.5), endPoint: .bottom)
            VStack(alignment: .leading, spacing: 3) {
                Text(m.item.displayTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.white)
                TimelineView(RelativeTimeSchedule(created: m.item.created, paused: m.shell || !m.shown)) { ctx in
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.left.fill").font(.system(size: 8.5, weight: .semibold))
                        Text(m.item.conversationTitle).lineLimit(1).truncationMode(.tail)
                        Text("· \(RelativeTime.string(m.item.created, now: ctx.date))").fixedSize()
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                }
            }
            .padding(.horizontal, 13)
            .padding(.bottom, 12)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.6))
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 6) {
                if let c = m.countText {
                    HStack(spacing: 3) {
                        Image(systemName: "square.stack.fill").font(.system(size: 9, weight: .semibold))
                        Text(c).font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(Capsule().fill(.black.opacity(0.45)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
                }
                if !m.item.seen {
                    UnreadDot(pulse: m.pulse, size: 8)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.black.opacity(0.45)))
                        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                }
            }
            .padding(10)
        }
        .overlay(alignment: .topLeading) {
            if m.hovered {
                Circle()
                    .fill(.black.opacity(m.closeHovered ? 0.62 : 0.42))
                    .overlay(Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(.white))
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                    .frame(width: 22, height: 22)
                    .padding(10)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
    }
}

// MARK: shared pieces

struct ConversationLabel: View {
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "bubble.left.fill").font(.system(size: 8.5, weight: .semibold))
            Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.tail)
        }
        .foregroundStyle(.secondary)
    }
}

/// Time at rest; a close button on hover.
struct TimeOrClose: View {
    @ObservedObject var m: CardModel

    var body: some View {
        ZStack(alignment: .trailing) {
            TimelineView(RelativeTimeSchedule(created: m.item.created, paused: m.shell || !m.shown)) { ctx in
                Text(RelativeTime.string(m.item.created, now: ctx.date))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            .opacity(m.hovered ? 0 : 1)
            Circle()
                .fill(Color.primary.opacity(m.closeHovered ? 0.17 : 0.085))
                .overlay(
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(m.closeHovered ? .primary : .secondary)
                )
                .frame(width: 20, height: 20)
                .scaleEffect(m.hovered ? 1 : 0.6)
                .opacity(m.hovered ? 1 : 0)
        }
        .frame(height: 16)
    }
}

struct PreviewPane: View {
    let images: [NSImage]
    let count: Int
    private let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
            if let first = images.first {
                Color.clear
                    .overlay {
                        Image(nsImage: first).resizable().aspectRatio(contentMode: .fill)
                            .blur(radius: 26).saturation(1.25).opacity(0.9)
                    }
                    .clipped()
                Color.black.opacity(0.1)
            }
            HStack(spacing: 8) {
                ForEach(Array(images.prefix(3).enumerated()), id: \.offset) { _, img in
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                }
            }
            .padding(12)
            if count > 3 {
                Text("+\(count - 3)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).frame(height: 20)
                    .background(Capsule().fill(.black.opacity(0.5)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(8)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }
}

struct UnreadDot: View {
    var pulse: Bool
    var size: CGFloat = 8
    private let color = Color(nsColor: .controlAccentColor)

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.55), lineWidth: 1.5)
                .frame(width: size, height: size)
                .scaleEffect(pulse ? 2.8 : 1)
                .opacity(pulse ? 0 : 0.9)
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .shadow(color: color.opacity(0.45), radius: 3)
        }
        .frame(width: size, height: size)
    }
}

struct ThumbStack: View {
    let images: [NSImage]
    let count: Int
    var side: CGFloat = 54
    var radius: CGFloat = 11
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }

    var body: some View {
        ZStack {
            if images.count >= 3 {
                tile(images[2]).scaleEffect(0.8).rotationEffect(.degrees(-10)).offset(x: -5, y: -2)
            }
            if images.count >= 2 {
                tile(images[1]).scaleEffect(0.86).rotationEffect(.degrees(9)).offset(x: 6, y: -2)
            }
            if let first = images.first {
                tile(first).scaleEffect(images.count > 1 ? 0.9 : 1).offset(y: images.count > 1 ? 1.5 : 0)
            } else {
                shape.fill(Color.primary.opacity(0.08))
                    .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
                    .frame(width: side, height: side)
            }
        }
        .frame(width: side, height: side)
    }

    private func tile(_ img: NSImage) -> some View {
        Image(nsImage: img)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: side, height: side)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.13), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.14), radius: 1.5, y: 0.5)
    }
}

struct RelativeTimeSchedule: TimelineSchedule {
    let created: Date
    let paused: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(created: created, current: startDate, singleShot: paused)
    }

    struct Entries: Sequence, IteratorProtocol {
        let created: Date
        var current: Date?
        let singleShot: Bool

        mutating func next() -> Date? {
            guard let now = current else { return nil }
            if singleShot {
                current = nil
                return now
            }
            let age = now.timeIntervalSince(created)
            if age < 45 {
                current = Swift.max(now.addingTimeInterval(1), created.addingTimeInterval(45))
            } else if age < 3600 {
                let nextOffset = Swift.min(3600, (floor((age - 30) / 60) + 1) * 60 + 30)
                current = Swift.max(now.addingTimeInterval(1), created.addingTimeInterval(nextOffset))
            } else {
                let cal = Calendar.current
                let nextDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))
                current = nextDay.map { Swift.max(now.addingTimeInterval(60), $0) }
            }
            return now
        }
    }
}

enum RelativeTime {
    private static let lock = NSLock()
    private static let hmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    static func string(_ date: Date, now: Date) -> String {
        let s = now.timeIntervalSince(date)
        if s < 45 { return L10n.tr("刚刚", "Just now") }
        if s < 3600 {
            let mins = max(1, Int((s / 60).rounded()))
            return L10n.tr("\(mins) 分钟前", "\(mins)m ago")
        }
        lock.lock()
        let hm = hmFormatter.string(from: date)
        lock.unlock()
        if Calendar.current.isDate(date, inSameDayAs: now) { return hm }
        return L10n.tr("昨天 \(hm)", "Yesterday \(hm)")
    }
}
