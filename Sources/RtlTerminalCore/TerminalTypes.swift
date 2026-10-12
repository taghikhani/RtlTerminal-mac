import Foundation

public struct TerminalColor: Hashable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public struct TerminalStyle: Hashable, Sendable {
    public var foreground: TerminalColor?
    public var background: TerminalColor?
    // Keep indexed colors distinct from an identical explicit RGB value.
    public var foregroundPaletteIndex: Int?
    public var backgroundPaletteIndex: Int?
    public var bold = false
    public var italic = false
    public var dim = false
    public var underline = false
    public var strikethrough = false
    public var inverse = false
    public var hidden = false

    public init() {}

    /// Styles that are visible even on a space character.
    var hasVisibleStyle: Bool {
        background != nil || inverse || underline || strikethrough
    }
}

public struct TerminalModes: Equatable, Sendable {
    public var alternateScreen = false
    public var applicationCursorKeys = false
    public var bracketedPaste = false
    public var focusReporting = false
    public var mouseTrackingMode = 0
    public var sgrMouse = false
    public var synchronizedOutput = false

    public init() {}
}

public struct TerminalRun: Equatable, Sendable {
    public var text: String
    public var style: TerminalStyle

    public init(text: String, style: TerminalStyle) {
        self.text = text
        self.style = style
    }
}

/// An immutable terminal row. Reference identity lets renderers keep
/// per-row caches while unchanged rows are shared between snapshots.
public final class TerminalLine: @unchecked Sendable {
    public let runs: [TerminalRun]
    public let cellLength: Int
    public let containsRightToLeft: Bool
    public let text: String

    public init(runs: [TerminalRun], cellLength: Int) {
        self.runs = runs
        self.cellLength = cellLength
        text = runs.map(\.text).joined()
        containsRightToLeft = SmartRtl.containsRightToLeft(runs)
    }

    public func hasSameContent(as other: TerminalLine) -> Bool {
        self === other || (cellLength == other.cellLength && runs == other.runs)
    }
}

public struct TerminalSnapshot: Sendable {
    public var scrollback: [TerminalLine]
    public var screen: [TerminalLine]
    public var cursorRow: Int
    public var cursorColumn: Int
    public var cursorVisible: Bool
    public var scrollbackStartIndex: Int
    public var modes: TerminalModes
    public var title: String?
    public var revision: Int

    public var scrollbackCount: Int { scrollback.count }
    public var lineCount: Int { scrollback.count + screen.count }

    public func line(_ index: Int) -> TerminalLine {
        index < scrollback.count ? scrollback[index] : screen[index - scrollback.count]
    }

    /// Retained text, for session export.
    public var plainText: String {
        (0..<lineCount).map { line($0).text.replacingTrailingSpaces() }
            .joined(separator: "\n")
    }
}

extension String {
    func replacingTrailingSpaces() -> String {
        var result = self
        while result.last == " " { result.removeLast() }
        return result
    }
}
