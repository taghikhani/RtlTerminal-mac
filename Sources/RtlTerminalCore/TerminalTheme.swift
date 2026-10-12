import Foundation

public enum TerminalTheme: String, CaseIterable, Sendable {
    case dark
    case light

    private static let lightForegrounds: [TerminalColor] = [
        TerminalColor(36, 41, 47), TerminalColor(207, 34, 46),
        TerminalColor(17, 99, 41), TerminalColor(125, 78, 0),
        TerminalColor(5, 80, 174), TerminalColor(130, 80, 223),
        TerminalColor(27, 124, 131), TerminalColor(87, 96, 106),
        TerminalColor(110, 119, 129), TerminalColor(164, 14, 38),
        TerminalColor(26, 127, 55), TerminalColor(99, 60, 1),
        TerminalColor(9, 105, 218), TerminalColor(130, 80, 223),
        TerminalColor(49, 146, 170), TerminalColor(36, 41, 47)
    ]

    // Applications pick colors assuming a dark screen, so explicit
    // backgrounds become light tints that keep the remapped text readable.
    private static let lightBackgrounds: [TerminalColor] = [
        TerminalColor(246, 248, 250), TerminalColor(255, 235, 233),
        TerminalColor(218, 251, 225), TerminalColor(255, 248, 197),
        TerminalColor(221, 244, 255), TerminalColor(251, 239, 255),
        TerminalColor(216, 243, 246), TerminalColor(208, 215, 222),
        TerminalColor(208, 215, 222), TerminalColor(255, 206, 203),
        TerminalColor(172, 238, 187), TerminalColor(255, 236, 153),
        TerminalColor(182, 227, 255), TerminalColor(236, 215, 255),
        TerminalColor(179, 233, 239), TerminalColor(234, 238, 242)
    ]

    public var defaultForeground: TerminalColor {
        self == .light ? TerminalColor(36, 41, 47) : TerminalColor(230, 230, 230)
    }

    public var defaultBackground: TerminalColor {
        self == .light ? TerminalColor(255, 255, 255) : TerminalColor(12, 12, 12)
    }

    /// Light mode adapts the 16 ANSI colors only; 256-palette and RGB
    /// colors chosen by applications are preserved.
    public func mapForeground(_ color: TerminalColor, paletteIndex: Int?) -> TerminalColor {
        if self == .light, let index = paletteIndex, (0..<16).contains(index) {
            return Self.lightForegrounds[index]
        }
        return color
    }

    public func mapBackground(_ color: TerminalColor, paletteIndex: Int?) -> TerminalColor {
        if self == .light, let index = paletteIndex, (0..<16).contains(index) {
            return Self.lightBackgrounds[index]
        }
        return color
    }

    /// Final foreground/background for a style, after inverse, dim and hidden.
    public func colors(for style: TerminalStyle) -> (foreground: TerminalColor, background: TerminalColor) {
        var foreground = style.foreground.map { mapForeground($0, paletteIndex: style.foregroundPaletteIndex) }
            ?? defaultForeground
        var background = style.background.map { mapBackground($0, paletteIndex: style.backgroundPaletteIndex) }
            ?? defaultBackground
        if style.inverse { swap(&foreground, &background) }
        if style.dim {
            func blend(_ fg: UInt8, _ bg: UInt8) -> UInt8 { UInt8(Double(fg) * 0.55 + Double(bg) * 0.45) }
            foreground = TerminalColor(
                blend(foreground.red, background.red),
                blend(foreground.green, background.green),
                blend(foreground.blue, background.blue))
        }
        if style.hidden { foreground = background }
        return (foreground, background)
    }
}
