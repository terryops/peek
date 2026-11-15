import AppKit
import ServiceManagement
import SwiftUI

enum Language: String {
    case zh, en
}

enum L10n {
    nonisolated(unsafe) static var override: Language?

    static var current: Language {
        if let override { return override }
        if let env = ProcessInfo.processInfo.environment["PEEK_LANG"]?.lowercased() {
            if env.hasPrefix("zh") { return .zh }
            if env.hasPrefix("en") { return .en }
        }
        if let pref = UserDefaults.standard.string(forKey: "language")?.lowercased() {
            if pref.hasPrefix("zh") { return .zh }
            if pref.hasPrefix("en") { return .en }
        }
        if let first = Locale.preferredLanguages.first?.lowercased(), first.hasPrefix("zh") {
            return .zh
        }
        return .en
    }

    static var isChinese: Bool { current == .zh }
    static func tr(_ zh: String, _ en: String) -> String { isChinese ? zh : en }
}

extension View {
    @ViewBuilder
    func peekGlass<S: InsettableShape>(in shape: S) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        }
        #else
        self.background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        #endif
    }
}

enum SystemIntegration {
    private static var legacyLaunchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Paths.bundleID).plist")
    }

    static var launchAtLoginEnabled: Bool {
        if FileManager.default.fileExists(atPath: legacyLaunchAgentURL.path) { return true }
        return SMAppService.mainApp.status == .enabled
    }

    static func setLaunchAtLogin(_ enabled: Bool) throws {
        let fm = FileManager.default
        if !enabled, fm.fileExists(atPath: legacyLaunchAgentURL.path) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["bootout", "gui/\(getuid())/\(Paths.bundleID)"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            try? fm.removeItem(at: legacyLaunchAgentURL)
        }
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }

    static var cliSymlinkURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("bin/peek")
    }

    static var isCLIInstalledForCurrentBundle: Bool {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath().path else { return false }
        let fm = FileManager.default
        for candidate in [cliSymlinkURL.path, "/usr/local/bin/peek", "/opt/homebrew/bin/peek"] {
            guard fm.fileExists(atPath: candidate) else { continue }
            let resolved = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
            if resolved == exe { return true }
        }
        return false
    }

    static func installCLISymlink() throws -> (link: URL, inPath: Bool) {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            throw RemoteError.invalid(L10n.tr("找不到 Peek 可执行文件", "Peek executable not found"))
        }
        let fm = FileManager.default
        let binDir = cliSymlinkURL.deletingLastPathComponent()
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: cliSymlinkURL.path) || (try? fm.attributesOfItem(atPath: cliSymlinkURL.path)) != nil {
            try fm.removeItem(at: cliSymlinkURL)
        }
        try fm.createSymbolicLink(at: cliSymlinkURL, withDestinationURL: exe)
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path }
        return (cliSymlinkURL, pathDirs.contains(binDir.standardizedFileURL.path))
    }
}
