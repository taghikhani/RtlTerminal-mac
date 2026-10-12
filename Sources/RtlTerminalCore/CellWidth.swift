import Foundation

public enum CellWidth {
    /// Terminal columns used by a scalar: 0 for combining/format, 2 for wide.
    public static func of(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .format:
            return 0
        default:
            break
        }

        let value = scalar.value
        if value == 0x200b || value == 0x200c || value == 0x200d ||
            value == 0x2060 || value == 0xfeff || (0x1f3fb...0x1f3ff).contains(value) {
            return 0
        }

        return isWide(value) ? 2 : 1
    }

    /// Width of a grapheme cluster: its widest scalar.
    public static func of(_ character: Character) -> Int {
        character.unicodeScalars.map(of).max() ?? 0
    }

    static func isRegionalIndicator(_ value: UInt32) -> Bool {
        (0x1f1e6...0x1f1ff).contains(value)
    }

    private static func isWide(_ value: UInt32) -> Bool {
        (0x1100...0x115f).contains(value)
            || (0x2329...0x232a).contains(value)
            || (0x2e80...0xa4cf).contains(value)
            || (0xac00...0xd7a3).contains(value)
            || (0xf900...0xfaff).contains(value)
            || (0xfe10...0xfe19).contains(value)
            || (0xfe30...0xfe6f).contains(value)
            || (0xff00...0xff60).contains(value)
            || (0xffe0...0xffe6).contains(value)
            || (0x1f1e6...0x1f1ff).contains(value)
            || (0x1f300...0x1faff).contains(value)
            || (0x20000...0x3fffd).contains(value)
    }
}
