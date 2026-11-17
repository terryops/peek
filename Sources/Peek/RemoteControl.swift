import AppKit

enum RemoteControlAction: String, Codable {
    case list, add, connect, disconnect, remove, command
}

struct RemoteControlRequest: Codable {
    var id = UUID()
    var created = Date()
    var action: RemoteControlAction
    var host: String?
    var name: String?
}

struct RemoteHostInfo: Codable {
    var id: UUID
    var address: String
    var name: String
    var enabled: Bool
    var status: String
    var command: String?
    var error: String?
}

struct RemoteControlReply: Codable {
    var hosts: [RemoteHostInfo] = []
    var error: String?
}

struct RemoteCLIOptions {
    var action: RemoteControlAction
    var host: String?
    var name: String?
    var json = false
    var wait = false
    var timeout: TimeInterval = 60

    static func parse(_ args: [String]) throws -> Self {
        guard let verb = args.first, let action = RemoteControlAction(rawValue: verb) else {
            throw RemoteError.invalid(L10n.tr("需要 remote 子命令：list、add、connect、disconnect、remove、command", "Expected remote subcommand: list, add, connect, disconnect, remove, command"))
        }
        var options = Self(action: action)
        var i = 1
        while i < args.count {
            let parts = args[i].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let flag = String(parts[0])
            switch flag {
            case "--json" where parts.count == 1: options.json = true
            case "--wait" where parts.count == 1: options.wait = true
            case "--name", "--timeout":
                let value: String
                if parts.count == 2 { value = String(parts[1]) }
                else {
                    i += 1
                    guard i < args.count else { throw RemoteError.invalid("\(flag) requires a value") }
                    value = args[i]
                }
                if flag == "--name" { options.name = value }
                else {
                    guard let seconds = Double(value), seconds.isFinite, seconds > 0, seconds <= 300 else {
                        throw RemoteError.invalid("--timeout must be between 0 and 300 seconds")
                    }
                    options.timeout = seconds
                }
            default:
                guard !args[i].hasPrefix("-"), options.host == nil else {
                    throw RemoteError.invalid(L10n.tr("无效参数：\(args[i])", "Invalid argument: \(args[i])"))
                }
                options.host = args[i]
            }
            i += 1
        }
        guard action == .list || options.host?.isEmpty == false else {
            throw RemoteError.invalid(L10n.tr("需要 SSH 主机、名称或连接 ID", "A host, name or connection ID is required"))
        }
        if options.host?.isEmpty == true { throw RemoteError.invalid("Remote host cannot be empty") }
        guard options.name == nil || action == .add else {
            throw RemoteError.invalid("--name is only supported by remote add")
        }
        if action == .add, let host = options.host {
            try SSHConnection.validate(address: SSHConnection.normalize(address: host))
        }
        return options
    }
}

/// A private request/reply queue lets a short-lived CLI use the app's live SSH
/// connections. Notifications only wake the consumer; commands survive app startup.
enum RemoteControl {
    static let notification = Notification.Name("com.terryops.peek.remote-control")
    static var directory: URL { Paths.root.appendingPathComponent("remote-control", isDirectory: true) }
    static var usage: String {
        """
        peek remote list [host] [--json]
        peek remote add <user@host|SSH-alias> [--name name] [--wait] [--json]
        peek remote connect <host|name|id> [--wait] [--json]
        peek remote disconnect <host|name|id> [--json]
        peek remote remove <host|name|id> [--json]
        peek remote command <host|name|id> [--wait] [--json]
        --timeout <seconds>  (default: 60, maximum: 300)
        """
    }

    static func run(_ args: [String]) -> Int32 {
        if args.isEmpty || args.contains("--help") || args.contains("-h") { print(usage); return 0 }
        let json = args.contains("--json")
        do {
            let options = try RemoteCLIOptions.parse(args)
            let deadline = Date().addingTimeInterval(options.timeout)
            var reply = try send(RemoteControlRequest(action: options.action, host: options.host, name: options.name), deadline: deadline)
            if options.wait, [.add, .connect, .command].contains(options.action) {
                let id = reply.hosts.first?.id.uuidString ?? options.host
                while reply.error == nil, reply.hosts.first?.status != "connected" {
                    if let host = reply.hosts.first, ["failed", "disconnected"].contains(host.status) {
                        throw RemoteError.invalid(host.error ?? "Remote host is \(host.status)")
                    }
                    guard Date() < deadline else { throw RemoteError.invalid("Timed out waiting for remote connection") }
                    Thread.sleep(forTimeInterval: 0.1)
                    reply = try send(RemoteControlRequest(action: .list, host: id), deadline: deadline)
                }
            }
            if let error = reply.error { throw RemoteError.invalid(error) }
            if options.action == .command, reply.hosts.first?.command == nil {
                throw RemoteError.invalid(L10n.tr("主机尚未连接；请先运行 peek remote connect <主机> --wait", "Host is not connected; run peek remote connect <host> --wait first"))
            }
            if options.json { try printJSON(reply) }
            else if options.action == .command { print(reply.hosts.first?.command ?? "") }
            else {
                for host in reply.hosts {
                    print([host.id.uuidString, host.name, host.address, host.status, host.error ?? ""].joined(separator: "\t"))
                }
            }
            return 0
        } catch {
            if json { try? printJSON(RemoteControlReply(error: error.localizedDescription)) }
            else { return CLI.fail(error.localizedDescription) }
            return 1
        }
    }

    private static func printJSON(_ reply: RemoteControlReply) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(reply), as: UTF8.self))
    }

    private static func send(_ request: RemoteControlRequest, deadline: Date) throws -> RemoteControlReply {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let pending = directory.appendingPathComponent(request.id.uuidString + ".request")
        let response = directory.appendingPathComponent(request.id.uuidString + ".reply")
        defer { try? fm.removeItem(at: pending); try? fm.removeItem(at: response) }
        try JSONEncoder().encode(request).write(to: pending, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)
        CLI.notify(notification)
        if ProcessInfo.processInfo.environment["PEEK_HOME"] == nil { CLI.ensureAppRunning() }
        let responseDeadline = min(deadline, Date().addingTimeInterval(8))
        repeat {
            if let data = try? Data(contentsOf: response) { return try JSONDecoder().decode(RemoteControlReply.self, from: data) }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < responseDeadline
        throw RemoteError.invalid(L10n.tr("Peek 未响应远程管理请求；请确认接收端 App 已更新并正在运行", "Peek did not respond; ensure the receiver app is updated and running"))
    }

    @MainActor static func consume(using connections: RemoteConnections, at folder: URL = directory) {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "request" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
            let response = folder.appendingPathComponent(id.uuidString + ".reply")
            let reply: RemoteControlReply
            do {
                let request = try JSONDecoder().decode(RemoteControlRequest.self, from: Data(contentsOf: file))
                guard request.id == id, abs(request.created.timeIntervalSinceNow) < 330 else {
                    throw RemoteError.invalid("Expired or invalid remote management request")
                }
                try fm.removeItem(at: file)
                reply = try perform(request, using: connections)
            } catch {
                try? fm.removeItem(at: file)
                reply = RemoteControlReply(error: error.localizedDescription)
            }
            try? JSONEncoder().encode(reply).write(to: response, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: response.path)
        }
    }

    @MainActor static func perform(_ request: RemoteControlRequest, using connections: RemoteConnections) throws -> RemoteControlReply {
        if request.action == .list, request.host == nil {
            return RemoteControlReply(hosts: connections.hosts.map { info($0, using: connections) })
        }
        let host: RemoteHost
        if request.action == .add {
            guard let address = request.host else { throw RemoteError.invalid("Missing SSH host") }
            let id = try connections.add(address: address, label: request.name ?? "")
            guard let added = connections.hosts.first(where: { $0.id == id }) else { throw RemoteError.invalid("Host was not added") }
            host = added
        } else {
            guard let selector = request.host else { throw RemoteError.invalid("Missing remote host") }
            let exact = connections.hosts.filter { $0.id.uuidString.caseInsensitiveCompare(selector) == .orderedSame || $0.address == selector || $0.label == selector }
            let matches = exact.isEmpty ? connections.hosts.filter { $0.id.uuidString.lowercased().hasPrefix(selector.lowercased()) } : exact
            guard matches.count == 1, let found = matches.first else {
                throw RemoteError.invalid(matches.isEmpty ? "Remote host not found: \(selector)" : "Ambiguous remote host: \(selector); use its ID")
            }
            host = found
            switch request.action {
            case .connect:
                switch connections.states[host.id] ?? .disconnected {
                case .connected, .connecting, .installing, .reconnecting: break
                default: connections.connect(host.id)
                }
            case .disconnect: connections.disconnect(host.id)
            case .remove: connections.remove(host.id)
            default: break
            }
        }
        if request.action == .remove, !connections.hosts.contains(where: { $0.id == host.id }) {
            return RemoteControlReply(hosts: [RemoteHostInfo(id: host.id, address: host.address, name: host.label, enabled: false, status: "removed")])
        }
        let current = connections.hosts.first(where: { $0.id == host.id }) ?? host
        let result = info(current, using: connections)
        return RemoteControlReply(hosts: [result], error: request.action == .list ? nil : result.error)
    }

    @MainActor private static func info(_ host: RemoteHost, using connections: RemoteConnections) -> RemoteHostInfo {
        let status: String
        var error: String?
        switch connections.states[host.id] ?? .disconnected {
        case .disconnected: status = "disconnected"
        case .connecting: status = "connecting"
        case .installing: status = "installing"
        case .connected: status = "connected"
        case .reconnecting: status = "reconnecting"
        case .failed(let message): status = "failed"; error = message
        }
        return RemoteHostInfo(id: host.id, address: host.address, name: host.label, enabled: host.enabled,
                              status: status, command: connections.senderCommand(for: host.id), error: error)
    }
}
