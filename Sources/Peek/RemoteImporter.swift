import Foundation
import CryptoKit

/// Only verified, complete requests reach the existing atomic card publisher.
final class RemoteImporter {
    static let publicationLock = NSLock()
    typealias Publisher = ([String], String?, String?, PeekOrigin, RemoteCancellation?) throws -> PeekItem
    let downloadRoot: URL
    private let publisher: Publisher
    init(downloadRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Peek"),
         publisher: @escaping Publisher = { try CLI.publish($0, title: $1, source: $2, origin: $3, preserveGroups: true, cancellation: $4) }) {
        self.downloadRoot = downloadRoot
        self.publisher = publisher
    }
    static func safeHost(_ host: String) -> String {
        let clean = host.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) ? String($0) : "_" }.joined()
        return String(clean.prefix(100)).nonEmpty.flatMap { $0 == "." || $0 == ".." ? nil : $0 } ?? "remote"
    }
    func receive(_ message: RemoteMessage, host: String, cancellation: RemoteCancellation? = nil, read: (Int) throws -> Data) throws -> String {
        try cancellation?.check()
        try RemoteProtocol.validate(message)
        let fm = FileManager.default
        let parent = downloadRoot.appendingPathComponent(Self.safeHost(host), isDirectory: true)
        for directory in [downloadRoot, parent] {
            if (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw RemoteError.invalid("接收目录不能是符号链接")
            }
        }
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = parent.appendingPathComponent(message.requestId!, isDirectory: true)
        let stage = parent.appendingPathComponent(".partial-" + UUID().uuidString, isDirectory: true)
        guard !fm.fileExists(atPath: destination.path) else { throw RemoteError.invalid("请求已接收") }
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var committed = false, moved = false
        defer { try? fm.removeItem(at: stage); if moved && !committed { try? fm.removeItem(at: destination) } }
        for file in message.files! {
            let path = stage.appendingPathComponent(file.path)
            try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard fm.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw RemoteError.invalid("无法写入文件") }
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
            guard digest == file.sha256 else { throw RemoteError.invalid("文件校验失败") }
        }
        try cancellation?.check()
        Self.publicationLock.lock()
        defer { Self.publicationLock.unlock() }
        try cancellation?.check()
        try fm.moveItem(at: stage, to: destination)
        moved = true
        var origin = PeekOrigin()
        origin.conversation = message.conversation
        origin.remoteHost = host
        origin.rexSession = message.origin?.rexSession
        origin.rexBlock = message.origin?.rexBlock
        let paths = message.files!.filter(\.primary).map { destination.appendingPathComponent($0.path).path }
        let item = try publisher(paths, message.title, message.source ?? host, origin, cancellation)
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
        if cancelled { throw RemoteError.invalid("已取消") }
    }
    func commit(_ action: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw RemoteError.invalid("已取消") }
        try action()
    }
}
