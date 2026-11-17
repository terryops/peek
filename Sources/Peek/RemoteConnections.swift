import Foundation
import Combine
import AppKit

struct RemoteHost: Codable, Identifiable, Equatable {
    var id: UUID
    var address: String
    var label: String
    var enabled: Bool
}
enum RemoteConnectionState: Equatable {
    case disconnected, connecting, installing, connected, reconnecting, failed(String)
}

@MainActor final class RemoteConnections: ObservableObject {
    @Published private(set) var hosts: [RemoteHost] = []
    @Published private(set) var states: [UUID: RemoteConnectionState] = [:]
    @Published private(set) var commands: [UUID: String] = [:]
    private let storageDirectory: URL
    private let resourceDirectory: URL
    private let sshExecutable: URL
    private var targetId: UUID
    private var attempts: [UUID: SSHConnection] = [:]
    private var generations: [UUID: UUID] = [:]
    private var retries: [UUID: Task<Void, Never>] = [:]
    private var backoff: [UUID: Int] = [:]
    private var wakeObserver: NSObjectProtocol?
    private var running = false
    private struct Configuration: Codable { var targetId: UUID; var hosts: [RemoteHost] }

    init(storageDirectory: URL? = nil, resourceDirectory: URL? = nil, sshExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh")) {
        self.storageDirectory = storageDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Peek")
        self.resourceDirectory = resourceDirectory ?? Bundle.main.resourceURL ?? URL(fileURLWithPath: "Resources")
        self.sshExecutable = sshExecutable
        targetId = UUID()
        if let data = try? Data(contentsOf: self.storageDirectory.appendingPathComponent("remote-hosts.json")),
           let configuration = try? JSONDecoder().decode(Configuration.self, from: data) {
            targetId = configuration.targetId
            var ids = Set<UUID>()
            hosts = configuration.hosts.filter { (try? SSHConnection.validate(address: $0.address)) != nil && ids.insert($0.id).inserted }
        }
        states = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, .disconnected) })
    }
    @discardableResult func add(address rawAddress: String, label: String) throws -> UUID {
        let trimmed = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = SSHConnection.normalize(address: trimmed)
        try SSHConnection.validate(address: address)
        let explicitLabel = label.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let defaultLabel = address.hasPrefix("ssh://") ? String(address.dropFirst(6)) : address
        let cleanLabel = explicitLabel ?? defaultLabel
        if let index = hosts.firstIndex(where: { $0.address == address }) {
            let id = hosts[index].id
            if let explicitLabel, hosts[index].label != explicitLabel {
                let previous = hosts[index].label
                hosts[index].label = explicitLabel
                do { try persist() }
                catch { hosts[index].label = previous; throw error }
            }
            switch states[id] ?? .disconnected {
            case .connected, .connecting, .installing:
                break
            case .disconnected, .failed, .reconnecting:
                connect(id)
            }
            return id
        }
        let id = UUID()
        hosts.append(RemoteHost(id: id, address: address, label: cleanLabel, enabled: true))
        do { try persist() } catch { hosts.removeAll { $0.id == id }; throw error }
        connect(id)
        return id
    }
    func command(for id: UUID) -> String? { commands[id] }
    func senderCommand(for id: UUID) -> String? {
        command(for: id).map { $0 + " --to " + SSHConnection.quote(targetId.uuidString) }
    }
    func connect(_ id: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[index].enabled = true
        do { try persist() } catch {
            invalidate(id)
            hosts[index].enabled = false
            states[id] = .failed(L10n.tr("无法保存连接：\(error.localizedDescription)",
                                         "Cannot save connection: \(error.localizedDescription)"))
            return
        }
        backoff[id] = 0
        begin(id, reconnecting: false)
    }
    private func invalidate(_ id: UUID) {
        generations[id] = UUID()
        retries.removeValue(forKey: id)?.cancel()
        attempts.removeValue(forKey: id)?.cancel()
        commands.removeValue(forKey: id)
    }
    private func begin(_ id: UUID, reconnecting: Bool) {
        guard let host = hosts.first(where: { $0.id == id }), host.enabled else { return }
        invalidate(id)
        let generation = UUID()
        generations[id] = generation
        states[id] = reconnecting ? .reconnecting : .connecting
        let attempt = SSHConnection(host: host, targetId: targetId, resourceDirectory: resourceDirectory, sshExecutable: sshExecutable)
        attempts[id] = attempt
        attempt.onState = { [weak self] state in
            Task { @MainActor in
                guard let self, self.generations[id] == generation else { return }
                self.states[id] = state
            }
        }
        attempt.onReady = { [weak self] command in
            Task { @MainActor in
                guard let self, self.generations[id] == generation else { return }
                self.commands[id] = command; self.states[id] = .connected
                self.backoff[id] = 0
            }
        }
        attempt.onEnd = { [weak self, weak attempt] error, wasReady in
            let authenticationCancelled = attempt?.authenticationCancelled ?? false
            Task { @MainActor in
                guard let self, self.generations[id] == generation else { return }
                let endedGeneration = UUID()
                self.generations[id] = endedGeneration
                self.attempts.removeValue(forKey: id)
                self.commands.removeValue(forKey: id)
                if authenticationCancelled {
                    self.disconnect(id)
                    if self.states[id] == .disconnected {
                        self.states[id] = .failed(L10n.tr("SSH 验证已取消", "SSH verification cancelled"))
                    }
                } else if wasReady || reconnecting {
                    self.scheduleReconnect(id, generation: endedGeneration)
                } else { self.states[id] = .failed(error) }
            }
        }
        attempt.start()
    }
    private func scheduleReconnect(_ id: UUID, generation: UUID) {
        guard hosts.contains(where: { $0.id == id && $0.enabled }) else { return }
        states[id] = .reconnecting
        let n = min(backoff[id] ?? 0, 5)
        backoff[id] = n + 1
        retries[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(min(30, 1 << n)))
            guard !Task.isCancelled, let self, self.generations[id] == generation else { return }
            self.begin(id, reconnecting: true)
        }
    }
    func disconnect(_ id: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[index].enabled = false
        invalidate(id); states[id] = .disconnected
        do { try persist() } catch {
            states[id] = .failed(L10n.tr("连接已断开，无法保存：\(error.localizedDescription)",
                                         "Disconnected, failed to save: \(error.localizedDescription)"))
        }
    }
    func remove(_ id: UUID) {
        invalidate(id)
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        var removed = hosts.remove(at: index)
        do { try persist() } catch {
            removed.enabled = false
            hosts.insert(removed, at: index)
            states[id] = .failed(L10n.tr("连接已断开，无法移除：\(error.localizedDescription)",
                                         "Disconnected, failed to remove: \(error.localizedDescription)"))
            return
        }
        states.removeValue(forKey: id); generations.removeValue(forKey: id); backoff.removeValue(forKey: id)
    }
    func start() {
        guard !running else { return }; running = true
        for host in hosts where host.enabled { begin(host.id, reconnecting: false) }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.running else { return }
                for host in self.hosts where host.enabled {
                    if self.states[host.id] != .connected { self.begin(host.id, reconnecting: true) }
                }
            }
        }
    }
    func stop() {
        running = false
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver); self.wakeObserver = nil }
        for host in hosts { invalidate(host.id); states[host.id] = .disconnected }
    }
    private func persist() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: storageDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storageDirectory.path)
        let file = storageDirectory.appendingPathComponent("remote-hosts.json")
        try JSONEncoder().encode(Configuration(targetId: targetId, hosts: hosts)).write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
