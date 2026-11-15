import Foundation
import CryptoKit

/// Only verified, complete requests reach the existing atomic card publisher.
final class RemoteImporter {
    static let publicationLock = NSLock()
    private static let stampLock = NSLock()
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    typealias Publisher = ([String], String?, String?, PeekOrigin, RemoteCancellation?) throws -> PeekItem
    let downloadRoot: URL
    private let publisher: Publisher
    init(downloadRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Peek"),
         publisher: @escaping Publisher = { try CLI.publish($0, title: $1, source: $2, origin: $3, preserveGroups: true, cancellation: $4) }) {
        self.downloadRoot = downloadRoot
        self.publisher = publisher
    }
    static func safeHost(_ host: String) -> String {
        let stripped = host.hasPrefix("ssh://") ? String(host.dropFirst(6)) : host
        let clean = stripped.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) ? String($0) : "_" }.joined()
        return String(clean.prefix(100)).nonEmpty.flatMap { $0 == "." || $0 == ".." ? nil : $0 } ?? "remote"
    }
    static func folderName(for message: RemoteMessage, date: Date = Date()) -> String {
        stampLock.lock()
        let stamp = stampFormatter.string(from: date)
        stampLock.unlock()
        let rawLabel = message.title?.nonEmpty
            ?? message.files?.first(where: \.primary).map { ($0.name as NSString).deletingPathExtension.nonEmpty ?? $0.name }
            ?? "files"
        let unsafe = CharacterSet(charactersIn: "/\\:\0\n\r\t")
        let collapsed = rawLabel.unicodeScalars
            .map { unsafe.contains($0) ? "-" : String($0) }
            .joined()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        let label = String((collapsed.nonEmpty ?? "files").prefix(40))
        let compactID = (message.requestId ?? UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        let suffix = String(compactID.suffix(12))
        return "\(stamp)_\(label)_\(suffix)"
    }
    static func formatSource(explicit: String?, project: String?, host: String) -> String {
        if let s = explicit?.nonEmpty { return s }
        let displayHost = host.hasPrefix("ssh://") ? String(host.dropFirst(6)) : host
        if let p = project?.nonEmpty, p != "~", p != displayHost {
            return "\(displayHost) · \(p)"
        }
        return displayHost
    }
    func receive(_ message: RemoteMessage, host: String, cancellation: RemoteCancellation? = nil, read: (Int) throws -> Data) throws -> String {
        try cancellation?.check()
        try RemoteProtocol.validate(message)
        let fm = FileManager.default
        let parent = downloadRoot.appendingPathComponent(Self.safeHost(host), isDirectory: true)
        for directory in [downloadRoot, parent] {
            if (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw RemoteError.invalid(L10n.tr("接收目录不能是符号链接", "Download directory must not be a symlink"))
            }
        }
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let compactID = message.requestId!.replacingOccurrences(of: "-", with: "").lowercased()
        let idSuffix = "_" + String(compactID.suffix(12))
        let existingEntries = (try? fm.contentsOfDirectory(atPath: parent.path)) ?? []
        let destination = parent.appendingPathComponent(Self.folderName(for: message), isDirectory: true)
        guard !fm.fileExists(atPath: destination.path),
              !existingEntries.contains(where: { $0 == message.requestId! || $0.hasSuffix(idSuffix) }) else {
            throw RemoteError.invalid(L10n.tr("请求已接收", "Request already received"))
        }
        let stage = parent.appendingPathComponent(".partial-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var committed = false, moved = false
        defer { try? fm.removeItem(at: stage); if moved && !committed { try? fm.removeItem(at: destination) } }
        for file in message.files! {
            let path = stage.appendingPathComponent(file.path)
            try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard fm.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw RemoteError.invalid(L10n.tr("无法写入文件", "Cannot create file"))
            }
            let output = try FileHandle(forWritingTo: path)
            defer { try? output.close() }
            var remaining = file.size, hash = SHA256()
            while remaining > 0 {
                try cancellation?.check()
                let chunk = try RemoteProtocol.exact(Int(min(remaining, 64 * 1024)), read: read)
                try output.write(contentsOf: chunk)
                hash.update(data: chunk)
                remaining -= Int64(chunk.count)
            }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == file.sha256 else {
                throw RemoteError.invalid(L10n.tr("文件校验失败", "File checksum mismatch"))
            }
        }
        try cancellation?.check()
        Self.publicationLock.lock()
        defer { Self.publicationLock.unlock() }
        try cancellation?.check()
        let currentEntries = (try? fm.contentsOfDirectory(atPath: parent.path)) ?? []
        guard !fm.fileExists(atPath: destination.path),
              !currentEntries.contains(where: { $0 == message.requestId! || $0.hasSuffix(idSuffix) }) else {
            throw RemoteError.invalid(L10n.tr("请求已接收", "Request already received"))
        }
        try fm.moveItem(at: stage, to: destination)
        moved = true
        var origin = PeekOrigin()
        origin.conversation = message.conversation
        origin.remoteHost = host
        origin.rexSession = message.origin?.rexSession
        origin.rexBlock = message.origin?.rexBlock
        let paths = message.files!.filter(\.primary).map { destination.appendingPathComponent($0.path).path }
        let resolvedSource = Self.formatSource(explicit: message.source, project: message.origin?.project, host: host)
        let item = try publisher(paths, message.title, resolvedSource, origin, cancellation)
        committed = true
        return item.id
    }
}

/// Shared attempt cancellation also covers verified bytes waiting for publication.
final class RemoteCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw RemoteError.invalid(L10n.tr("已取消", "Cancelled")) }
    }
    func commit(_ action: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw RemoteError.invalid(L10n.tr("已取消", "Cancelled")) }
        try action()
    }
}
