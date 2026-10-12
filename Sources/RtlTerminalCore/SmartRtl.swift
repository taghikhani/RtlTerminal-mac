import Foundation

/// A run of UTF-16 code units laid out in one direction.
public struct DirectionalSpan: Equatable, Sendable {
    public var start: Int
    public var length: Int
    public var isRightToLeft: Bool

    public init(start: Int, length: Int, isRightToLeft: Bool) {
        self.start = start
        self.length = length
        self.isRightToLeft = isRightToLeft
    }
}

/// Directional spans for terminal rows. This is deliberately simpler than the
/// full Unicode bidi algorithm: English fragments, numbers and paths keep their
/// order inside Persian/Arabic text, and neutrals take the surrounding direction.
public enum SmartRtl {
    public static func shouldRightAlign(
        _ line: TerminalLine,
        smartRtlEnabled: Bool,
        preserveTerminalGrid: Bool
    ) -> Bool {
        smartRtlEnabled && !preserveTerminalGrid && line.containsRightToLeft
    }

    static func containsRightToLeft(_ runs: [TerminalRun]) -> Bool {
        runs.contains { run in run.text.unicodeScalars.contains(where: isStrongRtlLetter) }
    }

    public static func directionalSpans(
        _ text: String,
        baseRightToLeft: Bool
    ) -> [DirectionalSpan] {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return [] }

        let baseDirection = baseRightToLeft ? 1 : 0
        var directions = [Int](repeating: -1, count: units.count)
        var whitespace = [Bool](repeating: false, count: units.count)
        var index = 0

        for scalar in text.unicodeScalars {
            let direction = strongDirection(scalar)
            let isWhitespace = scalar.properties.isWhitespace
            for offset in 0..<UTF16.width(scalar) {
                directions[index + offset] = direction
                whitespace[index + offset] = isWhitespace
            }
            index += UTF16.width(scalar)
        }

        resolveBracketDirections(units, &directions)
        resolveNeutralDirections(&directions, whitespace, baseDirection)

        var spans: [DirectionalSpan] = []
        var spanStart = 0
        var spanDirection = directions[0]

        for index in 1..<units.count where directions[index] != spanDirection {
            spans.append(DirectionalSpan(
                start: spanStart,
                length: index - spanStart,
                isRightToLeft: spanDirection == 1))
            spanStart = index
            spanDirection = directions[index]
        }

        spans.append(DirectionalSpan(
            start: spanStart,
            length: units.count - spanStart,
            isRightToLeft: spanDirection == 1))
        return spans
    }

    private static func strongDirection(_ scalar: Unicode.Scalar) -> Int {
        if isStrongRtlLetter(scalar) { return 1 }

        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
             .modifierLetter, .otherLetter, .decimalNumber,
             .letterNumber, .otherNumber:
            return 0
        default:
            return -1
        }
    }

    private static func resolveBracketDirections(
        _ units: [UInt16],
        _ directions: inout [Int]
    ) {
        // ( ) [ ] { } < >
        let pairs: [UInt16: UInt16] = [0x29: 0x28, 0x5d: 0x5b, 0x7d: 0x7b, 0x3e: 0x3c]
        let openings = Set(pairs.values)
        // Top of stack is the last element.
        var brackets: [(character: UInt16, index: Int)] = []

        for (index, character) in units.enumerated() {
            if openings.contains(character) {
                brackets.append((character, index))
                continue
            }

            guard let expectedOpening = pairs[character],
                  let matchPosition = brackets.lastIndex(where: { $0.character == expectedOpening })
            else { continue }

            let openingIndex = brackets[matchPosition].index
            brackets.removeSubrange(matchPosition...)

            let contentDirection = enclosedDirection(
                directions,
                start: openingIndex + 1,
                end: index)

            guard contentDirection >= 0 else { continue }
            directions[openingIndex] = contentDirection
            directions[index] = contentDirection
        }
    }

    private static func enclosedDirection(
        _ directions: [Int],
        start: Int,
        end: Int
    ) -> Int {
        var found = -1

        for index in start..<max(start, end) where directions[index] >= 0 {
            if found >= 0 && found != directions[index] { return -1 }
            found = directions[index]
        }

        return found
    }

    private static func resolveNeutralDirections(
        _ directions: inout [Int],
        _ whitespace: [Bool],
        _ baseDirection: Int
    ) {
        var index = 0

        while index < directions.count {
            if directions[index] >= 0 {
                index += 1
                continue
            }

            let start = index
            var containsWhitespace = false

            while index < directions.count && directions[index] < 0 {
                containsWhitespace = containsWhitespace || whitespace[index]
                index += 1
            }

            let previous = start > 0 ? directions[start - 1] : baseDirection
            let next = index < directions.count ? directions[index] : baseDirection
            let resolved: Int
            if previous == next {
                resolved = previous
            } else if !containsWhitespace && (previous == 0 || next == 0) {
                resolved = 0
            } else {
                resolved = baseDirection
            }

            for neutral in start..<index { directions[neutral] = resolved }

            // A neutral prefix glued to an English word ("/usr", "--help")
            // belongs to that word, even after a Persian word and a space.
            if previous != next && containsWhitespace {
                if next == 0 {
                    var glued = index
                    while glued > start && !whitespace[glued - 1] { glued -= 1 }
                    for neutral in glued..<index { directions[neutral] = 0 }
                }
                if previous == 0 {
                    var glued = start
                    while glued < index && !whitespace[glued] { glued += 1 }
                    for neutral in start..<glued { directions[neutral] = 0 }
                }
            }
        }
    }

    public static func isStrongRtlLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
             .modifierLetter, .otherLetter:
            break
        default:
            return false
        }

        let value = scalar.value
        return (0x0590...0x08ff).contains(value)
            || (0xfb1d...0xfdff).contains(value)
            || (0xfe70...0xfeff).contains(value)
            || (0x10800...0x10fff).contains(value)
            || (0x1e800...0x1eeff).contains(value)
    }
}
