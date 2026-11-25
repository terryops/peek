import Foundation

/// Where everything lives. Cards are snapshots: the CLI copies each file into
/// the cache (APFS clone, so it costs no space) so a later screenshot written
/// to the same path can't change what an older card shows.
enum Paths {
    static let bundleID = "com.terryops.peek"
    static let changed = Notification.Name("com.terryops.peek.changed")
    static let debug = Notification.Name("com.terryops.peek.debug")
    static let quit = Notification.Name("com.terryops.peek.quit")

    /// PEEK_HOME lets tests use a throwaway store.
    static let root: URL = {
        if let custom = ProcessInfo.processInfo.environment["PEEK_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Peek", isDirectory: true)
    }()
    static var items: URL { root.appendingPathComponent("items", isDirectory: true) }
    static var incoming: URL { root.appendingPathComponent("incoming", isDirectory: true) }
    static var lock: URL { root.appendingPathComponent(".lock") }
    static var debugOut: URL { root.appendingPathComponent("debug.json") }

    /// Items older than this are deleted, copies included.
    static let retention: TimeInterval = 24 * 3600

    static func ensure() {
        for dir in [items, incoming] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

struct PeekFile: Codable, Hashable {
    /// Original file name, shown on the card.
    var name: String
    /// File name inside the item's `files/` folder.
    var stored: String
    /// Absolute path the file was pushed from.
    var original: String
}

/// Which conversation pushed the card, and how to get back to it.
struct PeekOrigin: Codable, Hashable {
    /// Conversation title: a /rename name, the Rex session label, or the first prompt.
    var conversation: String?
    /// The user's latest prompt in that conversation when the card was pushed.
    var prompt: String?
    var sessionID: String?
    var rexSession: String?
    var rexBlock: String?
    var rexBin: String?
    /// Bundle identifier of the terminal app that sent the card.
    var terminalBundle: String?
    var remoteHost: String?

    var jumpTarget: (session: String, executable: String)? {
        guard remoteHost == nil, let session = rexSession?.nonEmpty, let executable = rexBin?.nonEmpty,
              FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        return (session, executable)
    }

    var canJump: Bool { jumpTarget != nil }
}

struct PeekItem: Codable, Identifiable, Equatable {
    var id: String
    var created: Date
    var title: String?
    var source: String
    var files: [PeekFile]
    var seen = false
    var dismissed = false
    var lastOpened: Date?
    var origin: PeekOrigin?

    /// Header line on cards: the conversation, else the project folder.
    var conversationTitle: String { origin?.conversation?.nonEmpty ?? source }

    var allImages: Bool {
        files.allSatisfy { ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "avif", "svg"]
            .contains(($0.name as NSString).pathExtension.lowercased()) }
    }

    var dir: URL { Paths.items.appendingPathComponent(id, isDirectory: true) }
    var urls: [URL] { files.map { dir.appendingPathComponent("files", isDirectory: true).appendingPathComponent($0.stored) } }

    /// Original paths that still exist, falling back to our copies.
    var revealURLs: [URL] {
        zip(files, urls).map { file, copy in
            FileManager.default.fileExists(atPath: file.original) ? URL(fileURLWithPath: file.original) : copy
        }
    }

    var displayTitle: String {
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        guard let name = files.first?.name else { return "" }
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? name : base
    }
}

enum Store {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Newest first.
    static func loadAll() -> [PeekItem] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Paths.items.path) else { return [] }
        var out: [PeekItem] = []
        for name in names where !name.hasPrefix(".") {
            let json = Paths.items.appendingPathComponent(name).appendingPathComponent("item.json")
            guard let data = try? Data(contentsOf: json),
                  let item = try? decoder.decode(PeekItem.self, from: data),
                  item.id == name else { continue }
            out.append(item)
        }
        return out.sorted { ($0.created, $0.id) > ($1.created, $1.id) }
    }

    static func save(_ item: PeekItem, in dir: URL? = nil) throws {
        let target = (dir ?? item.dir).appendingPathComponent("item.json")
        try encoder.encode(item).write(to: target, options: .atomic)
    }

    static func remove(_ id: String) {
        try? FileManager.default.removeItem(at: Paths.items.appendingPathComponent(id, isDirectory: true))
    }

    static func removeAll() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: Paths.items.path)) ?? [] {
            try? fm.removeItem(at: Paths.items.appendingPathComponent(name))
        }
    }

    /// Deletes expired items and half-written leftovers. Returns how many items went.
    @discardableResult
    static func cleanup(now: Date = Date()) -> Int {
        let fm = FileManager.default
        var removed = 0
        for item in loadAll() where now.timeIntervalSince(item.created) > Paths.retention {
            remove(item.id)
            removed += 1
        }
        // Folders without a readable item.json (crashed CLI, manual tinkering).
        let valid = Set(loadAll().map(\.id))
        for name in (try? fm.contentsOfDirectory(atPath: Paths.items.path)) ?? [] where !valid.contains(name) {
            let url = Paths.items.appendingPathComponent(name)
            if age(of: url, now: now) > 600 { try? fm.removeItem(at: url) }
        }
        for name in (try? fm.contentsOfDirectory(atPath: Paths.incoming.path)) ?? [] {
            let url = Paths.incoming.appendingPathComponent(name)
            if age(of: url, now: now) > 600 { try? fm.removeItem(at: url) }
        }
        return removed
    }

    private static func age(of url: URL, now: Date) -> TimeInterval {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
        return now.timeIntervalSince(date)
    }

    private static let idLock = NSLock()
    private static let idFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f
    }()

    static func makeID(_ date: Date = Date()) -> String {
        idLock.lock()
        let stamp = idFormatter.string(from: date)
        idLock.unlock()
        let tail = String(UUID().uuidString.prefix(4)).lowercased()
        return "\(stamp)-\(tail)"
    }
}

extension String {
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
