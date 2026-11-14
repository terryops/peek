import Foundation
import CryptoKit
import Testing
@testable import Peek

@Suite(.serialized)
struct RemoteTransferTests {
    let hello = Data("hello".utf8)
    func file(_ path: String = "0/report.txt", body: Data = Data("hello".utf8), primary: Bool = true) -> RemoteFile {
        RemoteFile(path: path, name: URL(fileURLWithPath: path).lastPathComponent, original: "/remote/\(path)", size: Int64(body.count), sha256: SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined(), primary: primary)
    }
    func push(_ files: [RemoteFile]) -> RemoteMessage { RemoteMessage(kind: "push", requestId: UUID().uuidString, source: "project", files: files) }
    func reader(_ data: Data, fragment: Int = 2) -> (Int) -> Data {
        var offset = 0
        return { count in let n = min(count, fragment, data.count - offset); defer { offset += n }; return data.subdata(in: offset..<offset+n) }
    }
    @Test func fragmentedFrames() throws {
        let message = push([file()])
        let decoded = try RemoteProtocol.readFrame(reader(RemoteProtocol.frame(message), fragment: 1))
        #expect(decoded.requestId == message.requestId)
        #expect(decoded.files?.first?.size == 5)
    }
    @Test func rejectsMalformedManifests() {
        for path in ["/root", "../evil", "a//b", "a/./b", "a\\b", "a/../b", "a\u{0}b"] {
            #expect(throws: (any Error).self) { try RemoteProtocol.validate(push([file(path)])) }
        }
        for paths in [["0/A.txt", "0/a.txt"], ["0/é.txt", "0/e\u{301}.txt"], ["0/a", "0/a/b"]] {
            #expect(throws: (any Error).self) { try RemoteProtocol.validate(push(paths.map { file($0) })) }
        }
        var bad = push([file()]); bad.requestId = "bad"; #expect(throws: (any Error).self) { try RemoteProtocol.validate(bad) }
        bad = push([file()]); bad.files![0].size = -1; #expect(throws: (any Error).self) { try RemoteProtocol.validate(bad) }
        bad = push([file()]); bad.files![0].size = 67_108_865; #expect(throws: (any Error).self) { try RemoteProtocol.validate(bad) }
        bad = push([file(primary: false)]); #expect(throws: (any Error).self) { try RemoteProtocol.validate(bad) }
    }
    @Test func importKeepsDocumentAssetsSeparate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = Data("<img src='assets/a.txt'>".utf8), b = Data("second".utf8)
        var message = push([file("0/report.html", body: a), file("0/assets/a.txt", primary: false), file("1/report.html", body: a), file("1/assets/a.txt", body: b, primary: false)])
        message.origin = RemoteOrigin(rexSession: "remote-session", rexBlock: "remote-block")
        message.conversation = "Remote conversation"
        let id = try RemoteImporter(downloadRoot: root).receive(message, host: "user@server", read: reader(a + hello + a + b))
        let item = try #require(Store.loadAll().first { $0.id == id })
        defer { Store.remove(id) }
        #expect(item.files.count == 2)
        #expect(try Data(contentsOf: item.urls[0].deletingLastPathComponent().appendingPathComponent("assets/a.txt")) == hello)
        #expect(try Data(contentsOf: item.urls[1].deletingLastPathComponent().appendingPathComponent("assets/a.txt")) == b)
        #expect(item.origin?.canJump == false)
        #expect(item.origin?.rexBin == nil)
        #expect(item.origin?.terminalBundle == nil)
        #expect(item.origin?.remoteHost == "user@server")
        #expect(item.origin?.conversation == "Remote conversation")
    }
    @Test func hashAndEOFRemoveStaging() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let importer = RemoteImporter(downloadRoot: root)
        for bytes in [Data("wrong".utf8), Data("he".utf8)] {
            #expect(throws: (any Error).self) { try importer.receive(push([file()]), host: "server", read: reader(bytes)) }
            let entries = (try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? []
            #expect(entries.allSatisfy { !$0.contains("report.txt") && !$0.contains(".partial") })
        }
    }
    @Test func oldOriginsDecode() throws {
        let origin = try JSONDecoder().decode(PeekOrigin.self, from: Data("{\"conversation\":\"old\"}".utf8))
        #expect(origin.conversation == "old")
        #expect(origin.canJump == false)
    }
    @Test func rejectsSSHOptionAndShellInjection() throws {
        for address in ["-oProxyCommand=evil", "a b", "host;touch", "a\nwhoami", "$(evil)", "", "user@"] {
            #expect(throws: (any Error).self) { try SSHConnection.validate(address: address) }
        }
        for address in ["officemac", "user@example.com", "user@192.168.1.2", "user@[::1]"] {
            try SSHConnection.validate(address: address)
        }
    }
    @Test @MainActor func cancellationDoesNotPublishStaleState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("ssh")
        try Data("#!/bin/sh\nsleep 1\necho failed >&2\nexit 1\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let manager = RemoteConnections(storageDirectory: root.appendingPathComponent("config"), resourceDirectory: root, sshExecutable: script)
        let id = try manager.add(address: "fixture", label: "Fixture")
        try await Task.sleep(for: .milliseconds(100))
        manager.disconnect(id)
        manager.connect(id)
        manager.remove(id)
        try await Task.sleep(for: .milliseconds(1400))
        #expect(manager.hosts.isEmpty)
        #expect(manager.states[id] == nil)
        #expect(manager.command(for: id) == nil)
        let reload = RemoteConnections(storageDirectory: root.appendingPathComponent("config"), resourceDirectory: root)
        #expect(reload.hosts.isEmpty)
        manager.stop()
    }

    @Test func frameBoundsAndUnsupportedMessages() throws {
        for prefix: [UInt8] in [[0, 0, 0, 0], [0, 16, 0, 1], [0, 0, 0, 1, 255], [0, 0, 0, 9, 123]] {
            #expect(throws: (any Error).self) { try RemoteProtocol.readFrame(reader(Data(prefix))) }
        }
        for message in [RemoteMessage(version: 2, kind: "ready"), RemoteMessage(kind: "other")] {
            #expect(throws: (any Error).self) { try RemoteProtocol.readFrame(reader(RemoteProtocol.frame(message))) }
        }
        var valid = push([file()]); valid.files![0].size = 67_108_864
        try RemoteProtocol.validate(valid)
        valid.files!.append(file("1/next"))
        #expect(throws: (any Error).self) { try RemoteProtocol.validate(valid) }
        valid = push([file()]); valid.files![0].sha256 = String(repeating: "F", count: 64)
        #expect(throws: (any Error).self) { try RemoteProtocol.validate(valid) }
    }
    @Test func rejectsDirectoryCaseAliasesAndSymlinkParents() throws {
        #expect(throws: (any Error).self) { try RemoteProtocol.validate(push([file("0/A/one"), file("0/a/two")])) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("server"), withDestinationURL: outside)
        #expect(throws: (any Error).self) { try RemoteImporter(downloadRoot: root).receive(push([file()]), host: "server", read: reader(hello)) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
    @Test func cancellationClosesAcceptedTransferAndRemovesStaging() async throws {
        let before = Set(Store.loadAll().map(\.id))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("remote"), withIntermediateDirectories: true)
        try Data("binary fixture".utf8).write(to: root.appendingPathComponent("remote/peek-darwin-arm64"))
        let id = UUID(), script = root.appendingPathComponent("ssh")
        let ready = RemoteMessage(kind: "ready", targetId: id.uuidString, command: "'/remote/peek'")
        let message = push([file()])
        let wire = try RemoteProtocol.frame(ready) + RemoteProtocol.frame(message) + Data("he".utf8)
        try wire.write(to: root.appendingPathComponent("ssh.wire"))
        let shell = """
        #!/bin/sh
        case "$*" in
        *'uname -s'*) printf 'Darwin\narm64\n';;
        *'mktemp'*) cat >/dev/null; printf '{"command":"/remote/peek"}';;
        *' bridge '*) echo $$ > "$0.pid"; cat "$0.wire"; exec sleep 30;;
        *) exit 0;;
        esac
        """
        try Data(shell.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let downloads = root.appendingPathComponent("downloads")
        let connection = SSHConnection(host: RemoteHost(id: UUID(), address: "fixture", label: "Fixture", enabled: true), targetId: id, resourceDirectory: root, sshExecutable: script, importer: RemoteImporter(downloadRoot: downloads))
        connection.start()
        var staged = false
        for _ in 0..<100 {
            if ((try? FileManager.default.subpathsOfDirectory(atPath: downloads.path)) ?? []).contains(where: { $0.hasSuffix("report.txt") }) { staged = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(staged)
        connection.cancel()
        for _ in 0..<100 {
            if !((try? FileManager.default.subpathsOfDirectory(atPath: downloads.path)) ?? []).contains(where: { $0.contains(".partial") }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!((try? FileManager.default.subpathsOfDirectory(atPath: downloads.path)) ?? []).contains(where: { $0.contains(".partial") }))
        #expect(!FileManager.default.fileExists(atPath: downloads.appendingPathComponent("fixture/" + message.requestId!).path))
        #expect(Set(Store.loadAll().map(\.id)) == before)
    }

    @Test @MainActor func replacingConnectedAttemptKeepsNewGenerationAndCommand() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("remote"), withIntermediateDirectories: true)
        try Data("binary fixture".utf8).write(to: root.appendingPathComponent("remote/peek-darwin-arm64"))
        let target = UUID(), command = "'/remote/peek with spaces'"
        let configuration = try JSONSerialization.data(withJSONObject: ["targetId": target.uuidString, "hosts": []])
        try configuration.write(to: root.appendingPathComponent("remote-hosts.json"))
        try RemoteProtocol.frame(RemoteMessage(kind: "ready", targetId: target.uuidString, command: command)).write(to: root.appendingPathComponent("ssh.wire"))
        let script = root.appendingPathComponent("ssh")
        let shell = """
        #!/bin/sh
        case "$*" in
        *'uname -s'*) printf 'Darwin\narm64\n';;
        *'mktemp'*) cat >/dev/null; printf '{"command":"/remote/peek"}';;
        *' bridge '*) echo "$PEEK_ASKPASS_CANCEL" >> "$0.paths"; cat "$0.wire"; exec sleep 30;;
        *) exit 0;;
        esac
        """
        try Data(shell.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let manager = RemoteConnections(storageDirectory: root, resourceDirectory: root, sshExecutable: script)
        let id = try manager.add(address: "fixture", label: "Fixture")
        for _ in 0..<100 { if manager.states[id] == .connected { break }; try await Task.sleep(for: .milliseconds(20)) }
        #expect(manager.states[id] == .connected)
        #expect(manager.command(for: id) == command)
        manager.disconnect(id)
        manager.connect(id)
        for _ in 0..<100 { if manager.states[id] == .connected { break }; try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(500))
        #expect(manager.states[id] == .connected)
        #expect(manager.command(for: id) == command)
        let paths = try String(contentsOf: root.appendingPathComponent("ssh.paths"), encoding: .utf8).split(separator: "\n")
        #expect(paths.count == 2)
        #expect(Set(paths).count == 2)
        manager.stop()
        #expect(manager.states[id] == .disconnected)
        #expect(manager.command(for: id) == nil)
        let loaded = RemoteConnections(storageDirectory: root, resourceDirectory: root)
        #expect(loaded.hosts.first?.enabled == true)
        manager.remove(id)
    }

    @Test func probeTimeoutReportsFailureInsteadOfHangingState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("ssh")
        try Data("#!/bin/sh\ncase \"$*\" in *'-O'*) exit 0;; *) exec sleep 30;; esac\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let completion = DispatchSemaphore(value: 0)
        let connection = SSHConnection(host: RemoteHost(id: UUID(), address: "fixture", label: "Fixture", enabled: true), targetId: UUID(), resourceDirectory: root, sshExecutable: script, transferTimeout: 0.1)
        connection.onEnd = { _, wasReady in #expect(!wasReady); completion.signal() }
        connection.start()
        let ended = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: completion.wait(timeout: .now() + 1) == .success) }
        }
        #expect(ended)
        connection.cancel()
    }

    @Test func cancellationAfterBodyBeforePublicationCreatesNoCard() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let message = push([file()]), token = RemoteCancellation()
        let before = Set(Store.loadAll().map(\.id))
        let bodyRead = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        let result = TransferResult()
        RemoteImporter.publicationLock.lock()
        DispatchQueue.global().async {
            do {
                var offset = 0
                let id = try RemoteImporter(downloadRoot: root).receive(message, host: "server", cancellation: token) { count in
                    let n = min(count, self.hello.count - offset)
                    defer { offset += n; if offset == self.hello.count { bodyRead.signal() } }
                    return self.hello.subdata(in: offset..<offset+n)
                }
                result.set(id: id)
            } catch { result.set(error: error) }
            finished.signal()
        }
        let received = bodyRead.wait(timeout: .now() + 2) == .success
        token.cancel()
        RemoteImporter.publicationLock.unlock()
        let ended = finished.wait(timeout: .now() + 2) == .success
        let created = Store.loadAll().filter { !before.contains($0.id) }
        defer { created.forEach { Store.remove($0.id) }; try? FileManager.default.removeItem(at: root) }
        #expect(received)
        #expect(ended)
        #expect(result.error != nil)
        #expect(result.id == nil)
        #expect(created.isEmpty)
        let destination = root.appendingPathComponent("server/" + message.requestId!)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!((try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? []).contains(where: { $0.contains(".partial") }))
    }

    @Test func importReturnsItsOwnCardDuringConcurrentLocalPublication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let localPath = root.appendingPathComponent("local.txt")
        try Data("local".utf8).write(to: localPath)
        let before = Set(Store.loadAll().map(\.id)), remoteResult = TransferResult(), localResult = TransferResult()
        defer {
            Store.loadAll().filter { !before.contains($0.id) }.forEach { Store.remove($0.id) }
            try? FileManager.default.removeItem(at: root)
        }
        let importer = RemoteImporter(downloadRoot: root.appendingPathComponent("downloads")) { paths, title, source, origin, cancellation in
            let remote = try CLI.publish(paths, title: title, source: source, origin: origin, preserveGroups: true, cancellation: cancellation)
            remoteResult.set(id: remote.id)
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                do {
                    var local = try CLI.publish([localPath.path], title: "Local", source: "local")
                    // Make the newest-first ordering deterministic even when both
                    // publications serialize their dates to the same second.
                    local.created = remote.created.addingTimeInterval(60)
                    try Store.save(local)
                    localResult.set(id: local.id)
                } catch { localResult.set(error: error) }
                finished.signal()
            }
            guard finished.wait(timeout: .now() + 2) == .success else { throw RemoteError.invalid("local publication timed out") }
            return remote
        }
        let id = try importer.receive(push([file()]), host: "server", read: reader(hello))
        #expect(localResult.error == nil)
        #expect(localResult.id != nil)
        #expect(id == remoteResult.id)
        #expect(id != localResult.id)
        let item = try #require(Store.loadAll().first { $0.id == id })
        #expect(item.origin?.remoteHost == "server")
    }

    @Test func cancellationAtPublicationEntryDiscardsDownloads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let token = RemoteCancellation(), message = push([file()])
        let before = Set(Store.loadAll().map(\.id))
        let importer = RemoteImporter(downloadRoot: root) { paths, title, source, origin, cancellation in
            // The complete destination has moved and the publication lock was
            // acquired. Cancellation must still stop the card's commit.
            token.cancel()
            return try CLI.publish(paths, title: title, source: source, origin: origin, preserveGroups: true, cancellation: cancellation)
        }
        #expect(throws: (any Error).self) { try importer.receive(message, host: "server", cancellation: token, read: reader(hello)) }
        #expect(Set(Store.loadAll().map(\.id)) == before)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("server/" + message.requestId!).path))
        #expect(!((try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? []).contains(where: { $0.contains(".partial") }))
    }

}


private final class TransferResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedID: String?
    private var storedError: Error?
    var id: String? { lock.lock(); defer { lock.unlock() }; return storedID }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return storedError }
    func set(id: String) { lock.lock(); storedID = id; lock.unlock() }
    func set(error: Error) { lock.lock(); storedError = error; lock.unlock() }
}
