import Foundation

/// One grapheme cluster placed on screen. Offsets are UTF-16, matching
/// NSString/CoreText indices.
public struct LayoutCell: Equatable {
    public var start: Int
    public var length: Int
    public var x: Double
    public var width: Double
    public var isRightToLeft: Bool
    public var style: TerminalStyle
    /// Terminal columns this cluster occupies in the PTY's grid.
    public var gridColumns: Int
}

/// A piece of text drawn in one call. Left-to-right text is drawn cell by
/// cell at exact grid positions; right-to-left text is drawn per word so
/// Persian/Arabic letters are shaped and joined.
public struct LayoutGlyph: Equatable {
    public var text: String
    public var start: Int
    public var x: Double
    public var width: Double
    public var isRightToLeft: Bool
    public var style: TerminalStyle
}

public struct RowLayout {
    public let line: TerminalLine
    public let text: String
    public var cells: [LayoutCell]
    public var glyphs: [LayoutGlyph]
    /// Style per UTF-16 offset of `text`.
    public let styles: [TerminalStyle]

    public init(
        line: TerminalLine,
        smartRtl: Bool,
        rowRtl: Bool,
        preserveTerminalGrid: Bool,
        cellWidth: Double,
        viewportWidth: Double
    ) {
        self.line = line
        text = line.text
        var styles: [TerminalStyle] = []
        for run in line.runs {
            styles.append(contentsOf: repeatElement(run.style, count: run.text.utf16.count))
        }
        self.styles = styles

        let rightAlign = rowRtl || SmartRtl.shouldRightAlign(
            line, smartRtlEnabled: smartRtl, preserveTerminalGrid: preserveTerminalGrid)
        // Paragraph direction is independent of grid alignment. Shaping of
        // Arabic/Persian spans stays active even when Smart RTL is off.
        let baseRtl = rowRtl || (smartRtl && line.containsRightToLeft)
        let utf16Count = text.utf16.count
        let spans = line.containsRightToLeft
            ? SmartRtl.directionalSpans(text, baseRightToLeft: baseRtl)
            : utf16Count == 0 ? [] : [DirectionalSpan(start: 0, length: utf16Count, isRightToLeft: false)]

        var members: [(start: Int, length: Int, width: Int, whitespace: Bool)] = []
        var offset = 0
        for character in text {
            let length = character.utf16.count
            members.append((offset, length, CellWidth.of(character), character.isWhitespace))
            offset += length
        }

        let totalWidth = Double(members.reduce(0) { $0 + $1.width }) * cellWidth
        var x = rightAlign ? max(0, viewportWidth - totalWidth) : 0
        var cells: [LayoutCell] = []
        var glyphs: [LayoutGlyph] = []
        let units = Array(text.utf16)

        func substring(_ start: Int, _ end: Int) -> String {
            String(decoding: units[start..<end], as: UTF16.self)
        }

        for span in baseRtl ? spans.reversed() : spans {
            let spanMembers = members.filter { $0.start >= span.start && $0.start < span.start + span.length }
            let spanWidth = Double(spanMembers.reduce(0) { $0 + $1.width }) * cellWidth
            var advance = 0.0
            let firstCell = cells.count

            for member in spanMembers {
                let width = Double(member.width) * cellWidth
                let cellX = x + (span.isRightToLeft ? spanWidth - advance - width : advance)
                let style = member.start < styles.count ? styles[member.start] : TerminalStyle()
                cells.append(LayoutCell(
                    start: member.start, length: member.length, x: cellX, width: width,
                    isRightToLeft: span.isRightToLeft, style: style, gridColumns: member.width))
                advance += width
                // Latin and box-drawing glyphs sit at exact cell boundaries.
                if !span.isRightToLeft && width > 0 {
                    glyphs.append(LayoutGlyph(
                        text: substring(member.start, member.start + member.length),
                        start: member.start, x: cellX, width: width,
                        isRightToLeft: false, style: style))
                }
            }

            // Keep word separators at cell width: shaping a padded span would
            // scale its spaces along with proportional Arabic glyphs. Words
            // still cross ANSI style boundaries, so letters stay joined.
            if span.isRightToLeft && !spanMembers.isEmpty {
                var index = 0
                while index < spanMembers.count {
                    let first = index
                    let whitespace = spanMembers[first].whitespace
                    index += 1
                    while index < spanMembers.count && spanMembers[index].whitespace == whitespace { index += 1 }

                    let startOffset = spanMembers[first].start
                    let endOffset = spanMembers[index - 1].start + spanMembers[index - 1].length
                    let segment = cells[firstCell...].filter { $0.start >= startOffset && $0.start < endOffset }
                    glyphs.append(LayoutGlyph(
                        text: substring(startOffset, endOffset),
                        start: startOffset,
                        x: segment.map(\.x).min() ?? x,
                        width: segment.reduce(0) { $0 + $1.width },
                        isRightToLeft: true,
                        style: styles[startOffset]))
                }
            }

            x += spanWidth
        }

        self.cells = cells
        self.glyphs = glyphs
    }

    public func style(at offset: Int) -> TerminalStyle {
        offset >= 0 && offset < styles.count ? styles[offset] : TerminalStyle()
    }

    /// Cells in logical (terminal) order.
    public var logicalCells: [LayoutCell] { cells.sorted { $0.start < $1.start } }

    public func cell(atX x: Double) -> LayoutCell? {
        cells.first { $0.width > 0 && x >= $0.x && x < $0.x + $0.width }
    }

    /// Terminal grid column (0-based) under a visual x position. Mouse
    /// reports use logical columns, not positions after bidi layout.
    public func logicalColumn(atX x: Double, cellWidth: Double) -> Int {
        let physical = Int((x / cellWidth).rounded(.down))
        guard line.containsRightToLeft, let hit = cell(atX: x) else { return physical }

        var column = 0
        for cell in logicalCells {
            if cell == hit {
                var fraction = (x - cell.x) / cell.width
                if cell.isRightToLeft { fraction = 1 - fraction }
                return column + clamp(Int(fraction * Double(cell.gridColumns)), 0, max(0, cell.gridColumns - 1))
            }
            column += cell.gridColumns
        }
        return physical
    }

    /// Cell covering a terminal grid column, for drawing the cursor.
    public func cell(atColumn target: Int) -> LayoutCell? {
        var column = 0
        for cell in logicalCells {
            if target >= column && target < column + max(1, cell.gridColumns) { return cell }
            column += cell.gridColumns
        }
        return nil
    }

    /// UTF-16 offset for a selection point at a visual x position.
    public func offset(atX x: Double) -> Int {
        let closest = cell(atX: x) ?? cells.min { abs($0.x + $0.width / 2 - x) < abs($1.x + $1.width / 2 - x) }
        guard let cell = closest else { return 0 }
        let after = x >= cell.x + cell.width / 2
        return after != cell.isRightToLeft ? cell.start + cell.length : cell.start
    }
}
