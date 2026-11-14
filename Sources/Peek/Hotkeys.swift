import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts (Carbon hot keys: no Accessibility permission needed).
/// Each can be changed or turned off: `defaults write com.terryops.peek hotkeyOpen "ctrl+opt+p"` ("" = off).
final class Hotkeys {
    static let shared = Hotkeys()

    struct Combo {
        let keyCode: UInt32
        let carbonMods: UInt32
        let menuKey: String
        let menuMods: NSEvent.ModifierFlags
        let display: String
    }

    enum Action: UInt32, CaseIterable {
        case open = 1, tuck, closeAll
        var defaultsKey: String {
            switch self {
            case .open: "hotkeyOpen"
            case .tuck: "hotkeyTuck"
            case .closeAll: "hotkeyCloseAll"
            }
        }
        var fallback: String {
            switch self {
            case .open: "ctrl+opt+p"
            case .tuck: "ctrl+opt+h"
            case .closeAll: "ctrl+opt+x"
            }
        }
    }

    private(set) var active: [Action: Combo] = [:]
    private var refs: [EventHotKeyRef] = []
    private var handlers: [Action: () -> Void] = [:]
    private var installed = false

    func start(_ handlers: [Action: () -> Void]) {
        self.handlers = handlers
        installHandler()
        for action in Action.allCases {
            let spec = UserDefaults.standard.string(forKey: action.defaultsKey) ?? action.fallback
            guard let combo = Self.parse(spec) else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5045_454B), id: action.rawValue)   // 'PEEK'
            let status = RegisterEventHotKey(combo.keyCode, combo.carbonMods, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                active[action] = combo
            } else {
                NSLog("Peek: shortcut \(combo.display) is taken (\(status)), skipped")
            }
        }
    }

    fileprivate func fire(_ id: UInt32) {
        guard let action = Action(rawValue: id) else { return }
        DispatchQueue.main.async { self.handlers[action]?() }
    }

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            Hotkeys.shared.fire(hk.id)
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Shows a registered shortcut on a menu item.
    func decorate(_ item: NSMenuItem, _ action: Action) {
        guard let c = active[action] else { return }
        item.keyEquivalent = c.menuKey
        item.keyEquivalentModifierMask = c.menuMods
    }

    // MARK: parsing "ctrl+opt+p" / "⌃⌥P"

    static func parse(_ spec: String) -> Combo? {
        let s = spec.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }
        var carbon: UInt32 = 0
        var flags: NSEvent.ModifierFlags = []
        var keyName = ""
        let symbols: [Character: String] = ["⌃": "ctrl", "⌥": "opt", "⇧": "shift", "⌘": "cmd"]
        var tokens: [String] = []
        if s.contains("+") {
            tokens = s.split(separator: "+").map(String.init)
        } else {
            var rest = ""
            for ch in s { if let m = symbols[ch] { tokens.append(m) } else { rest.append(ch) } }
            if !rest.isEmpty { tokens.append(rest) }
        }
        for t in tokens {
            switch t {
            case "ctrl", "control", "⌃": carbon |= UInt32(controlKey); flags.insert(.control)
            case "opt", "option", "alt", "⌥": carbon |= UInt32(optionKey); flags.insert(.option)
            case "shift", "⇧": carbon |= UInt32(shiftKey); flags.insert(.shift)
            case "cmd", "command", "⌘": carbon |= UInt32(cmdKey); flags.insert(.command)
            default: keyName = t
            }
        }
        guard carbon != 0, let (code, menuKey, glyph) = key(keyName) else { return nil }
        var display = ""
        if flags.contains(.control) { display += "⌃" }
        if flags.contains(.option) { display += "⌥" }
        if flags.contains(.shift) { display += "⇧" }
        if flags.contains(.command) { display += "⌘" }
        return Combo(keyCode: code, carbonMods: carbon, menuKey: menuKey, menuMods: flags, display: display + glyph)
    }

    private static func key(_ name: String) -> (UInt32, String, String)? {
        let letters: [Character: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
            "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
            "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            ".": kVK_ANSI_Period, ",": kVK_ANSI_Comma, "/": kVK_ANSI_Slash, ";": kVK_ANSI_Semicolon,
            "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, "`": kVK_ANSI_Grave,
        ]
        if name.count == 1, let c = name.first, let code = letters[c] {
            return (UInt32(code), String(c), String(c).uppercased())
        }
        switch name {
        case "return", "enter", "↩": return (UInt32(kVK_Return), "\r", "↩")
        case "space": return (UInt32(kVK_Space), " ", "Space")
        case "esc", "escape": return (UInt32(kVK_Escape), "\u{1b}", "⎋")
        case "delete", "backspace", "⌫": return (UInt32(kVK_Delete), "\u{8}", "⌫")
        case "left": return (UInt32(kVK_LeftArrow), String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)), "←")
        case "right": return (UInt32(kVK_RightArrow), String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), "→")
        case "up": return (UInt32(kVK_UpArrow), String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), "↑")
        case "down": return (UInt32(kVK_DownArrow), String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), "↓")
        default: return nil
        }
    }
}
