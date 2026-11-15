import AppKit

/// A separate process owns each prompt. A per-attempt cancellation file prevents
/// an old connection's cleanup from dismissing a newer connection's prompt.
enum SSHAskpass {
    static func run(_ question: String) -> Int32 {
        let cancel = ProcessInfo.processInfo.environment["PEEK_ASKPASS_CANCEL"]
        func attemptCancelled() -> Bool {
            guard let cancel else { return false }
            return FileManager.default.fileExists(atPath: cancel)
                || FileManager.default.fileExists(atPath: cancel + ".rejected")
        }
        // OpenSSH may invoke askpass again before the connection owner sees EOF.
        // An explicit rejection is terminal for this attempt, including retries.
        if attemptCancelled() { return 1 }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let alert = NSAlert()
        alert.messageText = L10n.tr("SSH 验证", "SSH Verification")
        alert.informativeText = question
        let confirmation = question.lowercased().contains("yes/no") || question.lowercased().contains("fingerprint")
        alert.addButton(withTitle: confirmation ? L10n.tr("信任并连接", "Trust & Connect") : L10n.tr("连接", "Connect"))
        alert.addButton(withTitle: L10n.tr("取消", "Cancel"))
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        if !confirmation { alert.accessoryView = field }
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            if attemptCancelled() {
                app.abortModal(); alert.window.orderOut(nil)
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        app.activate(ignoringOtherApps: true)
        if !confirmation { alert.window.initialFirstResponder = field }
        let result = alert.runModal()
        let cancelledByOwner = cancel.map { FileManager.default.fileExists(atPath: $0) } ?? false
        guard result == .alertFirstButtonReturn, !attemptCancelled() else {
            // Distinguish an explicit authentication rejection from a transport
            // failure, so a reconnect never reopens a cancelled prompt forever.
            if !cancelledByOwner, let cancel, !FileManager.default.fileExists(atPath: cancel + ".rejected") {
                FileManager.default.createFile(atPath: cancel + ".rejected", contents: Data())
            }
            return 1
        }
        print(confirmation ? "yes" : field.stringValue)
        return 0
    }
}
