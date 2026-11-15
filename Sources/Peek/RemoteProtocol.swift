import Foundation

struct RemoteFile: Codable {
    var path: String; var name: String; var original: String; var size: Int64; var sha256: String; var primary: Bool
}
struct RemoteMessage: Codable {
    var version = 1
    var kind: String
    var requestId: String?
    var targetId: String?
    var targetName: String?
    var command: String?
    var title: String?
    var conversation: String?
    var source: String?
    var origin: RemoteOrigin?
    var files: [RemoteFile]?
    var ok: Bool?
    var error: String?
    var cardId: String?
}
struct RemoteOrigin: Codable { var rexSession: String?; var rexBlock: String?; var project: String? }
enum RemoteError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let s) = self { return s }; return nil }
}
enum RemoteProtocol {
    static let maxHeader = 1_048_576
    static let maxBody: Int64 = 67_108_864
    static func exact(_ count: Int, read: (Int) throws -> Data) throws -> Data {
        var data = Data()
        while data.count < count {
            let chunk = try read(count - data.count)
            guard !chunk.isEmpty, chunk.count <= count - data.count else {
                throw RemoteError.invalid(L10n.tr("传输中断", "Transfer interrupted"))
            }
            data.append(chunk)
        }
        return data
    }
    static func readFrame(_ read: (Int) throws -> Data) throws -> RemoteMessage {
        let prefix = try exact(4, read: read)
        let n = prefix.reduce(0) { ($0 << 8) | Int($1) }
        guard n > 0, n <= maxHeader else {
            throw RemoteError.invalid(L10n.tr("无效消息长度", "Invalid frame length"))
        }
        let bytes = try exact(n, read: read)
        guard String(data: bytes, encoding: .utf8) != nil else {
            throw RemoteError.invalid(L10n.tr("无效 UTF-8", "Invalid UTF-8"))
        }
        let m = try JSONDecoder().decode(RemoteMessage.self, from: bytes)
        guard m.version == 1, ["ready", "push", "ack"].contains(m.kind) else {
            throw RemoteError.invalid(L10n.tr("不支持的协议", "Unsupported protocol"))
        }
        return m
    }
    static func frame(_ message: RemoteMessage) throws -> Data {
        let bytes = try JSONEncoder().encode(message)
        guard !bytes.isEmpty, bytes.count <= maxHeader else {
            throw RemoteError.invalid(L10n.tr("消息过大", "Frame too large"))
        }
        var n = UInt32(bytes.count).bigEndian
        return withUnsafeBytes(of: &n) { Data($0) } + bytes
    }
    static func canonical(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.contains("\\") && !path.contains("\u{0}") &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    static func validate(_ message: RemoteMessage) throws {
        guard message.version == 1, message.kind == "push", let id = message.requestId, UUID(uuidString: id) != nil,
              let files = message.files, !files.isEmpty, files.count <= 300, files.contains(where: \.primary) else {
            throw RemoteError.invalid(L10n.tr("无效文件清单", "Invalid file manifest"))
        }
        var total: Int64 = 0, paths = Set<String>()
        var spellings: [String: Data] = [:]
        for file in files {
            guard safePath(file.path), file.size >= 0, file.size <= maxBody - total,
                  file.sha256.utf8.count == 64, file.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  !file.name.isEmpty, !file.name.contains("\u{0}") else {
                throw RemoteError.invalid(L10n.tr("无效文件路径或大小", "Invalid file path or size"))
            }
            let parts = file.path.split(separator: "/")
            for end in 1...parts.count {
                let prefix = parts.prefix(end).joined(separator: "/")
                let key = canonical(prefix), spelling = Data(prefix.utf8)
                if let previous = spellings[key], previous != spelling {
                    throw RemoteError.invalid(L10n.tr("文件路径别名冲突", "File path alias conflict"))
                }
                spellings[key] = spelling
            }
            total += file.size
            guard paths.insert(canonical(file.path)).inserted else {
                throw RemoteError.invalid(L10n.tr("重复文件路径", "Duplicate file path"))
            }
        }
        for path in paths {
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                guard !paths.contains(parent) else {
                    throw RemoteError.invalid(L10n.tr("文件与目录冲突", "File and directory conflict"))
                }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
    }
}
