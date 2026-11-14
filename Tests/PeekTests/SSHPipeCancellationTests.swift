import Foundation
import Testing
import Darwin
@testable import Peek

@Suite(.serialized)
struct SSHPipeCancellationTests {
    @Test func brokenSSHPipeWritesSurviveAndCancellationReturnsPromptly() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("peek-pipe-supervisor-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = try fm.contentsOfDirectory(at: repository.appendingPathComponent("Sources/Peek"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "main.swift" }.map(\.path)
        let executable = root.appendingPathComponent("probe")
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compile.arguments = ["swiftc", "-parse-as-library", "-swift-version", "5"] + sources + [repository.appendingPathComponent("Tests/Fixtures/SSHPipeProbe.swift").path, "-o", executable.path]
        let compilerLog = root.appendingPathComponent("compiler.log")
        fm.createFile(atPath: compilerLog.path, contents: Data())
        let compilerOutput = try FileHandle(forWritingTo: compilerLog)
        compile.standardOutput = compilerOutput; compile.standardError = compilerOutput
        try compile.run(); compile.waitUntilExit(); try compilerOutput.close()
        let compilerText = try String(contentsOf: compilerLog, encoding: .utf8)
        try #require(compile.terminationStatus == 0, "probe compile: \(compilerText.suffix(2000))")
        for mode in ["upload", "ack-success", "ack-failure", "askpass-pre-rejected", "askpass-active-rejection", "askpass-owner-cancel", "askpass-auto-cancel"] {
            let fixture = root.appendingPathComponent(mode)
            let process = Process()
            process.executableURL = executable; process.arguments = [fixture.path, mode]
            var environment = ProcessInfo.processInfo.environment
            environment["PEEK_HOME"] = fixture.appendingPathComponent("store").path
            process.environment = environment
            let log = root.appendingPathComponent(mode + ".log")
            fm.createFile(atPath: log.path, contents: Data())
            let output = try FileHandle(forWritingTo: log)
            process.standardOutput = output; process.standardError = output
            try process.run()
            let began = Date()
            let deadline = began.addingTimeInterval(mode.hasPrefix("askpass-") ? 2 : 6)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning {
                process.terminate()
                let killDeadline = Date().addingTimeInterval(0.5)
                while process.isRunning, Date() < killDeadline { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit(); try output.close()
            let message = try String(contentsOf: log, encoding: .utf8)
            if mode.hasPrefix("askpass-") {
                let presentations = (try? String(contentsOf: fixture.appendingPathComponent("presentations"), encoding: .utf8)) ?? ""
                print("ASKPASS_PROBE=\(mode) REASON=\(process.terminationReason.rawValue) EXIT=\(process.terminationStatus) SECONDS=\(Date().timeIntervalSince(began)) PRESENTATIONS=\(presentations.split(separator: "\n").count)")
                #expect(process.terminationReason == .exit && process.terminationStatus == 1, "askpass must reject promptly without waiting for another Cancel")
                #expect(presentations.split(separator: "\n").count == (mode == "askpass-pre-rejected" ? 0 : 1))
                let rejection = fixture.appendingPathComponent("cancel.rejected")
                if mode == "askpass-owner-cancel" {
                    #expect(!fm.fileExists(atPath: rejection.path), "owner cancellation must not become authentication rejection")
                } else {
                    #expect(fm.fileExists(atPath: rejection.path), "manager must still observe authentication rejection")
                    if mode != "askpass-auto-cancel" {
                        #expect((try? String(contentsOf: rejection, encoding: .utf8)) == "retained")
                    }
                }
                continue
            }
            // The isolated child may be killed by the very bug under test.
            // Clean only the exact attempt directory recorded by our fixture.
            if let signalPath = try? String(contentsOf: fixture.appendingPathComponent("ssh.cancel"), encoding: .utf8) {
                let directory = URL(fileURLWithPath: signalPath).deletingLastPathComponent()
                if directory.deletingLastPathComponent().path == "/tmp",
                   directory.lastPathComponent.hasPrefix("peek-ssh-") { try? fm.removeItem(at: directory) }
            }
            print("PIPE_PROBE=\(mode) REASON=\(process.terminationReason.rawValue) EXIT=\(process.terminationStatus) \(message)")
            #expect(process.terminationReason == .exit && process.terminationStatus == 0,
                    "isolated \(mode) died: reason=\(process.terminationReason.rawValue) status=\(process.terminationStatus) \(message)")
            #expect(message.contains("PROBE_SURVIVED=\(mode)"))
        }
        // Optional integration uses an already-trusted password-capable endpoint.
        // No password is entered: the real native Cancel button rejects the first prompt.
        if let host = ProcessInfo.processInfo.environment["PEEK_TEST_ASKPASS_SSH_HOST"] {
            let fixture = root.appendingPathComponent("ssh-askpass-retries")
            try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
            let askpass = fixture.appendingPathComponent("askpass")
            try Data("""
            #!/bin/sh
            echo invoked >> "$PEEK_PROBE_ROOT/invocations"
            exec "$PEEK_PROBE_EXECUTABLE" "$PEEK_PROBE_ROOT" askpass-auto-cancel
            """.utf8).write(to: askpass)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass.path)
            let ssh = Process()
            ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            ssh.arguments = ["-T", "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10", "-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no", "-o", "NumberOfPasswordPrompts=3", host, "true"]
            var environment = ProcessInfo.processInfo.environment
            environment["SSH_ASKPASS"] = askpass.path; environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = "peek-regression"
            environment["PEEK_PROBE_ROOT"] = fixture.path; environment["PEEK_PROBE_EXECUTABLE"] = executable.path
            ssh.environment = environment
            ssh.standardInput = FileHandle.nullDevice
            let log = fixture.appendingPathComponent("ssh.log")
            fm.createFile(atPath: log.path, contents: Data())
            let output = try FileHandle(forWritingTo: log)
            ssh.standardOutput = output; ssh.standardError = output
            try ssh.run()
            let deadline = Date().addingTimeInterval(15)
            while ssh.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if ssh.isRunning {
                ssh.terminate()
                let killDeadline = Date().addingTimeInterval(0.5)
                while ssh.isRunning, Date() < killDeadline { Thread.sleep(forTimeInterval: 0.02) }
                if ssh.isRunning { kill(ssh.processIdentifier, SIGKILL) }
            }
            ssh.waitUntilExit(); try output.close()
            let invocations = try String(contentsOf: fixture.appendingPathComponent("invocations"), encoding: .utf8).split(separator: "\n").count
            let presentations = try String(contentsOf: fixture.appendingPathComponent("presentations"), encoding: .utf8).split(separator: "\n").count
            print("ACTUAL_SSH_ASKPASS EXIT=\(ssh.terminationStatus) INVOCATIONS=\(invocations) PRESENTATIONS=\(presentations)")
            #expect(ssh.terminationReason == .exit && ssh.terminationStatus == 255)
            #expect(invocations == 3, "ordinary SSH password retry policy stays intact")
            #expect(presentations == 1, "one Cancel must suppress later native dialogs within the attempt")
            #expect(fm.fileExists(atPath: fixture.appendingPathComponent("cancel.rejected").path))
        }
    }
}
