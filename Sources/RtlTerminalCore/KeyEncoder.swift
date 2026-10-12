import Foundation

public enum TerminalKey: Equatable, Sendable {
    case up, down, right, left, home, end
    case insert, delete, pageUp, pageDown
    case function(Int)
    case tab, enter, backspace, escape, space
}

public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1)
    public static let alt = KeyModifiers(rawValue: 2)
    public static let control = KeyModifiers(rawValue: 4)
}

/// xterm input sequences for special keys.
public enum KeyEncoder {
    public static func sequence(
        for key: TerminalKey,
        modifiers: KeyModifiers,
        applicationCursorKeys: Bool
    ) -> String? {
        let esc = "\u{1b}"
        let alt = modifiers.contains(.alt)
        // xterm modifier parameter: 1 + shift(1) + alt(2) + control(4).
        let modifier = 1 + modifiers.rawValue
        let hasModifier = modifier > 1

        switch key {
        case .tab:
            return modifiers.contains(.shift) ? "\(esc)[Z" : "\t"
        case .enter:
            return alt ? "\(esc)\r" : "\r"
        case .space:
            if modifiers.contains(.control) { return "\u{0}" }
            return alt ? "\(esc) " : " "
        case .backspace:
            if modifiers.contains(.control) { return "\u{08}" }
            return alt ? "\(esc)\u{7f}" : "\u{7f}"
        case .escape:
            return esc
        case .up, .down, .right, .left, .home, .end:
            let final: Character = switch key {
            case .up: "A"
            case .down: "B"
            case .right: "C"
            case .left: "D"
            case .home: "H"
            default: "F"
            }
            if hasModifier { return "\(esc)[1;\(modifier)\(final)" }
            return applicationCursorKeys ? "\(esc)O\(final)" : "\(esc)[\(final)"
        case .function(let number) where (1...4).contains(number):
            let final = ["P", "Q", "R", "S"][number - 1]
            return hasModifier ? "\(esc)[1;\(modifier)\(final)" : "\(esc)O\(final)"
        case .function(let number):
            let codes = [5: 15, 6: 17, 7: 18, 8: 19, 9: 20, 10: 21, 11: 23, 12: 24]
            guard let code = codes[number] else { return nil }
            return tilde(code, modifier)
        case .insert: return tilde(2, modifier)
        case .delete: return tilde(3, modifier)
        case .pageUp: return tilde(5, modifier)
        case .pageDown: return tilde(6, modifier)
        }
    }

    private static func tilde(_ code: Int, _ modifier: Int) -> String {
        modifier > 1 ? "\u{1b}[\(code);\(modifier)~" : "\u{1b}[\(code)~"
    }

    /// Control character for Ctrl+<key>, e.g. Ctrl+C → ETX.
    public static func controlCharacter(for character: Character) -> String? {
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case 0x61...0x7a: return String(UnicodeScalar(ascii - 0x60))   // a–z
        case 0x40...0x5f: return String(UnicodeScalar(ascii - 0x40))   // @ A–Z [ \ ] ^ _
        case 0x32: return "\u{0}"                                        // Ctrl+2
        case 0x33...0x37: return String(UnicodeScalar(ascii - 0x18))   // Ctrl+3…7
        case 0x38: return "\u{7f}"                                       // Ctrl+8
        case 0x2f: return "\u{1f}"                                       // Ctrl+/
        case 0x20: return "\u{0}"                                        // Ctrl+Space
        default: return nil
        }
    }

    /// SGR mouse report (mode 1006). x and y are 1-based grid positions.
    public static func sgrMouse(button: Int, x: Int, y: Int, released: Bool, modifiers: KeyModifiers) -> String {
        var code = button
        if modifiers.contains(.shift) { code += 4 }
        if modifiers.contains(.alt) { code += 8 }
        if modifiers.contains(.control) { code += 16 }
        return "\u{1b}[<\(code);\(x);\(y)\(released ? "m" : "M")"
    }

    /// Paste payload, wrapped for bracketed paste and with newlines as CR.
    public static func paste(_ text: String, bracketed: Bool) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
        guard bracketed else { return normalized }
        // Never let pasted text end bracketed paste early.
        let safe = normalized.replacingOccurrences(of: "\u{1b}[201~", with: "")
        return "\u{1b}[200~\(safe)\u{1b}[201~"
    }

    /// Quotes a file path for a POSIX shell, as Terminal.app does on drop.
    public static func shellEscaped(_ path: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+,@%:"))
        if !path.isEmpty && path.unicodeScalars.allSatisfy({ safe.contains($0) }) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
