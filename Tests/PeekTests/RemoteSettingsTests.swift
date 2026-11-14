import AppKit
import Testing
import Darwin
@testable import Peek

@Suite(.serialized) @MainActor
struct RemoteSettingsTests {
    @Test func emptyMenuKeepsRemoteManagementAccessible() {
        _ = NSApplication.shared
        let menu = StatusMenu()
        menu.update([])
        let snapshot = menu.snapshot()
        #expect(snapshot["visible"] as? Bool == true)
        #expect((snapshot["rows"] as? [String])?.contains(where: { $0.hasPrefix("远程机器…") }) == true)
    }

    @Test func remoteSettingsCommandIsAcceptedWithoutPublishingCard() {
        let before = Set(Store.loadAll().map(\.id))
        #expect(CLI.main(["--remote-settings"]) == 0)
        #expect(Set(Store.loadAll().map(\.id)) == before)
        // A startup handler sees the request even if no observer was registered.
        #expect(CLI.consumeSettingsRequest())
        #expect(!CLI.consumeSettingsRequest())
        // A later running-app request is independently consumable.
        #expect(CLI.main(["--remote-settings"]) == 0)
        #expect(CLI.consumeSettingsRequest())
    }

    @Test func persistenceFailureRemainsVisibleAndRemovalKeepsUsableRow() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("ssh")
        try Data("""
        #!/bin/sh
        case "$*" in
        *'uname -s'*) echo "$PEEK_ASKPASS_CANCEL" > "$0.cancel"; exec sleep 30;;
        *) exit 0;;
        esac
        """.utf8).write(to: script)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let config = root.appendingPathComponent("config")
        let manager = RemoteConnections(storageDirectory: config, sshExecutable: script)
        defer { manager.stop() }
        let id = try manager.add(address: "fixture", label: "Fixture")
        for _ in 0..<100 {
            if fm.fileExists(atPath: script.path + ".cancel") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let cancelPath = try String(contentsOfFile: script.path + ".cancel", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!fm.fileExists(atPath: cancelPath))
        try fm.removeItem(at: config)
        try Data("blocked".utf8).write(to: config)
        manager.disconnect(id)
        #expect(manager.hosts.first?.enabled == false)
        #expect(fm.fileExists(atPath: cancelPath))
        #expect(manager.command(for: id) == nil)
        if case .failed = manager.states[id] {} else { Issue.record("disconnect must report save failure") }
        manager.connect(id)
        if case .failed = manager.states[id] {} else { Issue.record("connect must report save failure") }
        manager.remove(id)
        #expect(manager.hosts.first?.id == id)
        if case .failed = manager.states[id] {} else { Issue.record("failed removal must retain an error row") }
    }
    @Test func cancelledReconnectAuthenticationDoesNotPromptAgain() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("remote"), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: root.appendingPathComponent("remote/peek-darwin-arm64"))
        let target = UUID()
        try JSONSerialization.data(withJSONObject: ["targetId": target.uuidString, "hosts": []])
            .write(to: root.appendingPathComponent("remote-hosts.json"))
        try RemoteProtocol.frame(RemoteMessage(kind: "ready", targetId: target.uuidString, command: "'/remote/peek with spaces'"))
            .write(to: root.appendingPathComponent("ssh.wire"))
        let script = root.appendingPathComponent("ssh")
        try Data("""
        #!/bin/sh
        case "$*" in
        *'uname -s'*)
            echo attempt >> "$0.calls"
            if test -e "$0.connected"; then touch "${PEEK_ASKPASS_CANCEL}.rejected"; exit 1; fi
            printf 'Darwin\narm64\n';;
        *'mktemp'*) cat >/dev/null; printf '{"command":"/remote/peek"}';;
        *' bridge '*) touch "$0.connected"; cat "$0.wire"; sleep 0.3;;
        *) exit 0;;
        esac
        """.utf8).write(to: script)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let manager = RemoteConnections(storageDirectory: root, resourceDirectory: root, sshExecutable: script)
        let id = try manager.add(address: "fixture", label: "Fixture")
        defer { manager.stop() }
        for _ in 0..<100 { if manager.states[id] == .connected { break }; try await Task.sleep(for: .milliseconds(20)) }
        #expect(manager.states[id] == .connected)
        let copied = try #require(manager.senderCommand(for: id))
        #expect(copied == "'/remote/peek with spaces' --to '" + target.uuidString + "'")
        try await Task.sleep(for: .seconds(3))
        if case .failed = manager.states[id] {} else { Issue.record("authentication cancel must stop retries") }
        #expect(manager.hosts.first?.enabled == false)
        let calls = try String(contentsOf: root.appendingPathComponent("ssh.calls"), encoding: .utf8)
        #expect(calls.split(separator: "\n").count == 2)
    }

    @Test func sshControlPathAllowsRealUnixSocketWithOpenSSHSuffix() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let script = root.appendingPathComponent("ssh")
        try Data("""
        #!/bin/sh
        for option do
            case "$option" in ControlPath=*) printf '%s' "${option#ControlPath=}" > "$0.control";; esac
        done
        case "$*" in *'uname -s'*) exec sleep 30;; *) exit 0;; esac
        """.utf8).write(to: script)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let connection = SSHConnection(host: RemoteHost(id: UUID(), address: "fixture", label: "Fixture", enabled: true), targetId: UUID(), resourceDirectory: root, sshExecutable: script)
        connection.start()
        defer { connection.cancel() }
        for _ in 0..<100 {
            if fm.fileExists(atPath: script.path + ".control") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let control = try String(contentsOfFile: script.path + ".control", encoding: .utf8)
        // OpenSSH binds a temporary name with a 17-byte random suffix before rename.
        let socketPath = control + ".LceL8JrRya5Bl0dB"
        let bytes = Array(socketPath.utf8CString)
        #expect(bytes.count <= MemoryLayout.size(ofValue: sockaddr_un().sun_path), "OpenSSH sun_path boundary: \(socketPath)")
        let offset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path)!
        let length = offset + bytes.count
        var storage = [UInt8](repeating: 0, count: max(length, MemoryLayout<sockaddr_un>.size))
        storage[0] = UInt8(length); storage[1] = UInt8(AF_UNIX)
        storage.replaceSubrange(offset..<length, with: bytes.map { UInt8(bitPattern: $0) })
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { Darwin.close(fd); unlink(socketPath) }
        let result = storage.withUnsafeBytes { buffer in
            Darwin.bind(fd, buffer.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(length))
        }
        #expect(result == 0, "actual AF_UNIX bind failed errno=\(errno), path bytes=\(bytes.count)")
        let attributes = try fm.attributesOfItem(atPath: URL(fileURLWithPath: control).deletingLastPathComponent().path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func settingsFieldSupportsCommandAWithoutSubmittingOnFocusChange() throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let manager = RemoteConnections(storageDirectory: root)
        let settings = RemoteSettings(connections: manager)
        settings.present()
        let window = try #require(settings.window)
        defer { window.orderOut(nil) }
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let fields = descendants(try #require(window.contentView)).compactMap { $0 as? NSTextField }
        let address = try #require(fields.first { $0.placeholderString != nil })
        window.makeFirstResponder(address)
        let editor = try #require(address.currentEditor() as? NSTextView)
        editor.string = "developer@example.com"
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        #expect(window.performKeyEquivalent(with: key))
        #expect(editor.selectedRange() == NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText("", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        window.makeFirstResponder(nil)
        #expect(manager.hosts.isEmpty)
        #expect(fields.filter { $0 != address }.allSatisfy { $0.stringValue != "请输入 SSH 主机名或 user@host" })
    }

}
