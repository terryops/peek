import AppKit
import Testing
@testable import Peek

@Suite(.serialized) @MainActor
struct RemoteControlTests {
    @Test func parsesAgentCommandsAndRejectsInvalidArguments() throws {
        let options = try RemoteCLIOptions.parse(["add", "user@example.com:2222", "--name", "Mac mini", "--json", "--wait", "--timeout=15"])
        #expect(options.action == .add)
        #expect(options.name == "Mac mini")
        #expect(options.json && options.wait && options.timeout == 15)
        for args in [["add"], ["add", "-oProxyCommand=evil"], ["list", "--timeout=nan"],
                     ["list", "--timeout=0"], ["list", ""], ["remove", "host", "--name=other"], ["connect", "a", "b"]] {
            #expect(throws: (any Error).self) { try RemoteCLIOptions.parse(args) }
        }
    }

    @Test func commandsSharePersistedConnectionsAndHandleDuplicateNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = RemoteConnections(storageDirectory: root, sshExecutable: URL(fileURLWithPath: "/usr/bin/false"))
        defer { manager.stop() }
        let first = try RemoteControl.perform(RemoteControlRequest(action: .add, host: "first", name: "Office"), using: manager)
        let id = try #require(first.hosts.first?.id)
        let again = try RemoteControl.perform(RemoteControlRequest(action: .add, host: "first", name: "Mac mini"), using: manager)
        #expect(again.hosts.first?.id == id)
        #expect(manager.hosts.count == 1)
        _ = try RemoteControl.perform(RemoteControlRequest(action: .add, host: "second", name: "Mac mini"), using: manager)
        #expect(throws: (any Error).self) {
            try RemoteControl.perform(RemoteControlRequest(action: .disconnect, host: "Mac mini"), using: manager)
        }
        let stopped = try RemoteControl.perform(RemoteControlRequest(action: .disconnect, host: id.uuidString), using: manager)
        #expect(stopped.hosts.first?.status == "disconnected")
        #expect(stopped.hosts.first?.enabled == false)
        let persisted = RemoteConnections(storageDirectory: root)
        #expect(persisted.hosts.first { $0.id == id }?.enabled == false)
        let removed = try RemoteControl.perform(RemoteControlRequest(action: .remove, host: String(id.uuidString.prefix(8))), using: manager)
        #expect(removed.hosts.first?.status == "removed")
        #expect(manager.hosts.count == 1)
        #expect(RemoteConnections(storageDirectory: root).hosts.count == 1)
    }

    @Test func persistenceFailuresAreReturnedToTheCaller() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = RemoteConnections(storageDirectory: root, sshExecutable: URL(fileURLWithPath: "/usr/bin/false"))
        defer { manager.stop() }
        let id = try manager.add(address: "fixture", label: "Fixture")
        try FileManager.default.removeItem(at: root)
        try Data("blocked".utf8).write(to: root)
        #expect(throws: (any Error).self) { try manager.add(address: "fixture", label: "Renamed") }
        #expect(manager.hosts.first?.label == "Fixture")
        let reply = try RemoteControl.perform(RemoteControlRequest(action: .remove, host: id.uuidString), using: manager)
        #expect(reply.error != nil)
        #expect(reply.hosts.first?.status == "failed")
        #expect(manager.hosts.count == 1)
    }

    @Test func requestQueueWorksAtStartupAndRejectsExpiredCommands() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let manager = RemoteConnections(storageDirectory: root.appendingPathComponent("config"))
        let current = RemoteControlRequest(action: .list)
        let expired = RemoteControlRequest(created: Date().addingTimeInterval(-400), action: .add, host: "expired")
        for request in [current, expired] {
            try JSONEncoder().encode(request).write(to: root.appendingPathComponent(request.id.uuidString + ".request"))
        }
        RemoteControl.consume(using: manager, at: root)
        let success = try JSONDecoder().decode(RemoteControlReply.self, from: Data(contentsOf: root.appendingPathComponent(current.id.uuidString + ".reply")))
        let failure = try JSONDecoder().decode(RemoteControlReply.self, from: Data(contentsOf: root.appendingPathComponent(expired.id.uuidString + ".reply")))
        #expect(success.error == nil && success.hosts.isEmpty)
        #expect(failure.error != nil)
        #expect(manager.hosts.isEmpty)
        #expect(!fm.fileExists(atPath: root.appendingPathComponent(current.id.uuidString + ".request").path))
    }
}
