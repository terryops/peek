import Foundation
import Darwin
import CryptoKit

/// One instance is one authentication/bridge attempt. Its socket, cancellation
/// signal and children are never shared with a replacement attempt.
final class SSHConnection {
    let host: RemoteHost
    let targetId: UUID
    let resourceDirectory: URL
    let sshExecutable: URL
    let importer: RemoteImporter
    let transferTimeout: TimeInterval
    private let lock = NSLock()
    private var cancelled = false
    private var directoryCreated = false
    private let publicationCancellation = RemoteCancellation()
    private var timedOut = false
    private var children: [Process] = []
    private var handles: [FileHandle] = []
    private var stderr = Data()
    private let privateDirectory: URL
    private var control: String { privateDirectory.appendingPathComponent("s").path }
    private var cancelFile: URL { privateDirectory.appendingPathComponent("cancel") }
    var authenticationCancelled: Bool { FileManager.default.fileExists(atPath: cancelFile.path + ".rejected") }
    var onState: ((RemoteConnectionState) -> Void)?
    var onReady: ((String) -> Void)?
    var onEnd: ((String, Bool) -> Void)?

    init(host: RemoteHost, targetId: UUID, resourceDirectory: URL, sshExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh"), importer: RemoteImporter = RemoteImporter(), transferTimeout: TimeInterval = 120) {
        self.host = host; self.targetId = targetId; self.resourceDirectory = resourceDirectory
        self.sshExecutable = sshExecutable; self.importer = importer; self.transferTimeout = transferTimeout
        // GUI TMPDIR is a long /var/folders path. OpenSSH appends a random
        // suffix before binding, and sockaddr_un.sun_path is only 104 bytes.
        privateDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("peek-ssh-" + UUID().uuidString)
    }
    static func validate(address: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@[]:%")
        guard !address.isEmpty, address.utf8.count <= 255, !address.hasPrefix("-"),
              address.unicodeScalars.allSatisfy(allowed.contains), address.filter({ $0 == "@" }).count <= 1,
              !address.hasSuffix("@"), !address.hasPrefix("@") else { throw RemoteError.invalid("请输入 SSH 主机名或 user@host") }
    }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private var didTimeout: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
    private var options: [String] {
        ["-T", "-o", "ControlMaster=auto", "-o", "ControlPersist=120", "-o", "ControlPath=\(control)",
         "-o", "StrictHostKeyChecking=ask", "-o", "ConnectTimeout=20", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"]
    }
    func start() { DispatchQueue.global(qos: .utility).async { self.run() } }
    func cancel() {
        publicationCancellation.cancel()
        lock.lock()
        if cancelled { lock.unlock(); return }
        cancelled = true
        let processes = children, streams = handles, ownsDirectory = directoryCreated
        lock.unlock()
        if ownsDirectory { FileManager.default.createFile(atPath: cancelFile.path, contents: Data()) }
        for process in processes where process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { if process.isRunning { kill(pid, SIGKILL) } }
        }
        // A close can wait on FileHandle's in-flight write/read lock. Stop the
        // peer first, then close off the main thread so Cancel stays responsive.
        DispatchQueue.global(qos: .utility).async {
            for stream in streams { try? stream.close() }
        }
        closeMaster()
    }
    private func closeMaster() {
        let p = Process(); p.executableURL = sshExecutable
        p.arguments = ["-S", control, "-O", "exit", host.address]
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        // Bound cleanup too; a custom SSH config must not keep shutdown alive.
        if (try? p.run()) != nil {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if p.isRunning { p.terminate() } }
        }
    }
    private func launch(_ command: String, input: Data? = nil) throws -> (Process, Pipe, Pipe) {
        let p = Process(), output = Pipe(), stdin = Pipe(), errors = Pipe()
        // Upload and both ACK paths share this descriptor. A disappeared SSH
        // reader must produce EPIPE, never terminate the GUI with SIGPIPE.
        guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        p.executableURL = sshExecutable; p.arguments = options + [host.address, command]
        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = resourceDirectory.appendingPathComponent("ssh-askpass").path
        env["SSH_ASKPASS_REQUIRE"] = "force"; env["DISPLAY"] = env["DISPLAY"] ?? "peek:0"
        env["PEEK_EXECUTABLE"] = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
        env["PEEK_ASKPASS_CANCEL"] = cancelFile.path
        p.environment = env
        p.standardOutput = output; p.standardInput = stdin; p.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { [weak self] h in
            let bytes = h.availableData
            guard let self, !bytes.isEmpty else { return }
            self.lock.lock(); self.stderr.append(bytes); self.stderr = Data(self.stderr.suffix(4096)); self.lock.unlock()
        }
        lock.lock()
        guard !cancelled else { lock.unlock(); throw RemoteError.invalid("已取消") }
        do { try p.run() } catch { lock.unlock(); errors.fileHandleForReading.readabilityHandler = nil; throw error }
        children.append(p); handles += [output.fileHandleForReading, stdin.fileHandleForWriting]
        lock.unlock()
        p.terminationHandler = { _ in errors.fileHandleForReading.readabilityHandler = nil; try? errors.fileHandleForReading.close() }
        if let input {
            DispatchQueue.global().async { try? stdin.fileHandleForWriting.write(contentsOf: input); try? stdin.fileHandleForWriting.close() }
        }
        return (p, output, stdin)
    }
    private func withDeadline<T>(_ work: () throws -> T) throws -> T {
        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard !self.cancelled else { self.lock.unlock(); return }
            self.timedOut = true
            self.lock.unlock()
            self.cancel()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + transferTimeout, execute: timeout)
        defer { timeout.cancel() }
        return try work()
    }
    private func command(_ command: String, input: Data? = Data()) throws -> Data {
        try withDeadline {
            let (p, out, _) = try launch(command, input: input)
            var bytes = Data()
            while let chunk = try out.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
                guard bytes.count + chunk.count <= RemoteProtocol.maxHeader else { throw RemoteError.invalid("SSH 输出过大") }
                bytes.append(chunk)
            }
            p.waitUntilExit()
            guard !isCancelled, p.terminationStatus == 0 else { throw RemoteError.invalid(errorText()) }
            return bytes
        }
    }
    private func errorText() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(data: stderr, encoding: .utf8)?.nonEmpty ?? "SSH 连接已中断"
    }
    private func run() {
        var ready = false, madeDirectory = false
        defer {
            cancel()
            // Never remove a directory this attempt did not create. Askpass
            // observes its private signal before the owned directory is removed.
            if madeDirectory {
                let dir = privateDirectory
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { try? FileManager.default.removeItem(at: dir) }
            }
        }
        do {
            try Self.validate(address: host.address)
            guard Darwin.mkdir(privateDirectory.path, 0o700) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            madeDirectory = true
            lock.lock(); directoryCreated = true; lock.unlock()
            onState?(.connecting)
            let probe = String(data: try command("uname -s; uname -m"), encoding: .utf8)?.split(whereSeparator: \.isNewline).map(String.init) ?? []
            guard probe.count == 2 else { throw RemoteError.invalid("无法识别远程系统") }
            let os: String, arch: String
            switch probe[0] { case "Darwin": os = "darwin"; case "Linux": os = "linux"; default: throw RemoteError.invalid("不支持的远程系统") }
            switch probe[1] { case "arm64", "aarch64": arch = "arm64"; case "x86_64", "amd64": arch = "amd64"; default: throw RemoteError.invalid("不支持的远程架构") }
            onState?(.installing)
            let binary = try Data(contentsOf: resourceDirectory.appendingPathComponent("remote/peek-\(os)-\(arch)"))
            let digest = SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined()
            let hashCommand = os == "darwin" ? "shasum -a 256" : "sha256sum"
            let install = "umask 077; p=$(mktemp \"${TMPDIR:-/tmp}/peek-remote-v1.XXXXXXXX\") || exit 1; trap 'rm -f \"$p\" \"$p.ready\"' EXIT HUP INT TERM; cat > \"$p\" && test \"$(wc -c < \"$p\")\" -eq \(binary.count) && test \"$(\(hashCommand) \"$p\" | cut -d ' ' -f 1)\" = \(Self.quote(digest)) && chmod 700 \"$p\" && mv \"$p\" \"$p.ready\" && \"$p.ready\" install"
            let result = try command(install, input: binary)
            struct Installed: Decodable { var command: String }
            let installed = try JSONDecoder().decode(Installed.self, from: result).command
            guard !installed.isEmpty, installed.utf8.count <= 4096, !installed.contains("\u{0}") else { throw RemoteError.invalid("无效远程命令") }
            // The install response is a shell-ready command, executed only on the
            // same authenticated remote host. It is never a local executable URL.
            let bridge = "exec \"$HOME/.local/share/peek/bin/peek-remote\" bridge --target \(Self.quote(targetId.uuidString)) --name \(Self.quote(Host.current().localizedName ?? "Mac")) --command \(Self.quote(installed))"
            let (_, output, input) = try launch(bridge)
            let read: (Int) throws -> Data = { try output.fileHandleForReading.read(upToCount: $0) ?? Data() }
            let initial = try withDeadline { try RemoteProtocol.readFrame(read) }
            guard initial.kind == "ready", initial.targetId?.lowercased() == targetId.uuidString.lowercased(), let sender = initial.command, !sender.isEmpty, sender.utf8.count <= 4096 else { throw RemoteError.invalid("无效连接确认") }
            guard !isCancelled else { return }
            ready = true; onReady?(sender)
            while !isCancelled {
                // Idle connections may wait indefinitely. Once the first header
                // byte arrives the complete frame must arrive within the deadline.
                var prefix = try read(1)
                guard !prefix.isEmpty else { throw RemoteError.invalid("SSH 连接已中断") }
                let message = try withDeadline {
                    try RemoteProtocol.readFrame { count in
                        if !prefix.isEmpty {
                            let bytes = Data(prefix.prefix(count)); prefix.removeFirst(bytes.count); return bytes
                        }
                        return try read(count)
                    }
                }
                guard message.kind == "push" else { throw RemoteError.invalid("无效推送消息") }
                let id: String
                do { id = try withDeadline { try importer.receive(message, host: host.address, cancellation: publicationCancellation, read: read) } }
                catch {
                    if !isCancelled {
                        let failure = RemoteMessage(kind: "ack", requestId: message.requestId, ok: false, error: String(error.localizedDescription.prefix(1024)))
                        try? input.fileHandleForWriting.write(contentsOf: RemoteProtocol.frame(failure))
                    }
                    // Any rejected body ends this stream; unread bytes can never
                    // be mistaken for the next request's frame.
                    throw error
                }
                guard !isCancelled else { return }
                try input.fileHandleForWriting.write(contentsOf: RemoteProtocol.frame(RemoteMessage(kind: "ack", requestId: message.requestId, ok: true, cardId: id)))
            }
        } catch {
            if didTimeout { onEnd?("SSH 连接超时", ready) }
            else if !isCancelled { onEnd?(error.localizedDescription, ready) }
        }
    }
}
