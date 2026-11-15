import Foundation
import Darwin
import CryptoKit
import AppKit

// Compiled with the real app sources by the supervisor test, never packaged.
@main struct SSHPipeProbe {
    static func main() throws {
        signal(SIGPIPE, SIG_DFL)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let mode = CommandLine.arguments[2]
        let fm = FileManager.default
        if mode.hasPrefix("askpass-") {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let cancel = root.appendingPathComponent("cancel").path
            setenv("PEEK_ASKPASS_CANCEL", cancel, 1)
            if mode == "askpass-pre-rejected" {
                fm.createFile(atPath: cancel + ".rejected", contents: Data("retained".utf8))
            }
            let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
                guard let window = NSApplication.shared.modalWindow, window.isVisible else { return }
                timer.invalidate()
                let log = root.appendingPathComponent("presentations")
                let previous = (try? Data(contentsOf: log)) ?? Data()
                try! (previous + Data("presented\n".utf8)).write(to: log)
                if mode == "askpass-active-rejection" {
                    fm.createFile(atPath: cancel + ".rejected", contents: Data("retained".utf8))
                } else if mode == "askpass-owner-cancel" {
                    fm.createFile(atPath: cancel, contents: Data())
                } else if mode == "askpass-auto-cancel" {
                    func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
                    let button = window.contentView.flatMap {
                        descendants($0).compactMap { $0 as? NSButton }.first { $0.title == "取消" || $0.title == "Cancel" }
                    }
                    guard let button else { exit(8) }
                    button.performClick(nil)
                }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            RunLoop.main.add(timer, forMode: .common)
            exit(SSHAskpass.run("Isolated regression prompt"))
        }
        try fm.createDirectory(at: root.appendingPathComponent("remote"), withIntermediateDirectories: true)
        try Data(repeating: 65, count: mode == "upload" ? 16 * 1024 * 1024 : 16)
            .write(to: root.appendingPathComponent("remote/peek-darwin-arm64"))
        let target = UUID()
        if mode != "upload" {
            let body = Data("hello".utf8)
            let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            let file = RemoteFile(path: "0/report.txt", name: "report.txt", original: "/remote/report.txt", size: 5,
                                  sha256: mode == "ack-success" ? digest : String(repeating: "0", count: 64), primary: true)
            let ready = RemoteMessage(kind: "ready", targetId: target.uuidString, command: "'/remote/peek'")
            let push = RemoteMessage(kind: "push", requestId: UUID().uuidString, source: "pipe-probe", files: [file])
            try (RemoteProtocol.frame(ready) + RemoteProtocol.frame(push) + body).write(to: root.appendingPathComponent("ssh.wire"))
        }
        let script = root.appendingPathComponent("ssh")
        try Data("""
        #!/bin/sh
        if test -n "$PEEK_ASKPASS_CANCEL"; then printf '%s' "$PEEK_ASKPASS_CANCEL" > "$0.cancel"; fi
        case "$*" in
        *'uname -s'*) printf 'Darwin\\narm64\\n';;
        *'mktemp'*)
            if test '\(mode)' = upload; then
                echo started > "$0.started"
                sleep 0.4
                exit 0
            fi
            cat >/dev/null; printf '{"command":"/remote/peek"}';;
        *' bridge '*) exec 0<&-; cat "$0.wire"; exec sleep 1;;
        *) exit 0;;
        esac
        """.utf8).write(to: script)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let ended = DispatchSemaphore(value: 0)
        let connection = SSHConnection(host: RemoteHost(id: UUID(), address: "fixture", label: "Fixture", enabled: true),
            targetId: target, resourceDirectory: root, sshExecutable: script,
            importer: RemoteImporter(downloadRoot: root.appendingPathComponent("downloads")))
        connection.onEnd = { _, _ in ended.signal() }
        connection.start()
        if mode == "upload" {
            let deadline = Date().addingTimeInterval(3)
            while !fm.fileExists(atPath: script.path + ".started"), Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
            guard fm.fileExists(atPath: script.path + ".started") else { exit(4) }
            Thread.sleep(forTimeInterval: 0.05)
            let began = Date()
            connection.cancel()
            let elapsed = Date().timeIntervalSince(began)
            print("CANCEL_SECONDS=\(elapsed)")
            guard elapsed < 0.15 else { exit(5) }
            // The broken reader must not kill this process after cancel returned.
            Thread.sleep(forTimeInterval: 1)
        } else {
            guard ended.wait(timeout: .now() + 3) == .success else { exit(6) }
            connection.cancel()
        }
        let cancelPath = try String(contentsOfFile: script.path + ".cancel", encoding: .utf8)
        let attemptDirectory = URL(fileURLWithPath: cancelPath).deletingLastPathComponent()
        let cleanupDeadline = Date().addingTimeInterval(3)
        while fm.fileExists(atPath: attemptDirectory.path), Date() < cleanupDeadline { Thread.sleep(forTimeInterval: 0.02) }
        guard !fm.fileExists(atPath: attemptDirectory.path) else { exit(7) }
        print("PROBE_SURVIVED=\(mode) OWNED_DIRECTORY_REMOVED=true")
    }
}
