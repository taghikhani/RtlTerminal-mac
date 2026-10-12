#if canImport(AppKit)
import AppKit
import CoreText
import RtlTerminalCore

protocol TerminalViewDelegate: AnyObject {
    func terminalView(_ view: TerminalView, send text: String)
    func terminalViewThemeDidChange(_ view: TerminalView)
}

/// Cell-based terminal surface. Only visible rows are shaped and drawn;
/// right-to-left words are shaped by CoreText and fitted to their cells.
final class TerminalView: NSView, NSTextInputClient, NSMenuItemValidation {
    static let inset: CGFloat = 6

    weak var delegate: TerminalViewDelegate?
    var optionAsMeta = false
    var isWindowKey = true { didSet { needsDisplay = true } }

    private(set) var snapshot: TerminalSnapshot?
    private(set) var theme: TerminalTheme = .dark
    private(set) var cellWidth: CGFloat = 8
    private(set) var lineHeight: CGFloat = 17
    private var font: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
    private var rtlFont: NSFont?
    private var ascent: CGFloat = 12
    private var descent: CGFloat = 4
    private var smartRtl = true
    private var rowRtl = false
    private var shapedRows: [Int: ShapedRow] = [:]
    private var glyphCache: [GlyphKey: CTLine] = [:]
    private var fontVariants: [Int: CTFont] = [:]
    private var colorCache: [TerminalColor: CGColor] = [:]
    private var anchor: TextPosition?
    private var selectionEnd: TextPosition?
    private var dragging = false
    private var reportedButton: Int?
    private var lastReportedCell: (x: Int, y: Int)?
    private var scrollAccumulator: CGFloat = 0
    private var marked: NSAttributedString?
    private var trackingArea: NSTrackingArea?

    static var temporaryFiles: [URL] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    var hasSelection: Bool {
        guard let anchor, let selectionEnd else { return false }
        return anchor != selectionEnd
    }

    private var modes: TerminalModes { snapshot?.modes ?? TerminalModes() }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        theme = Settings.shared.terminalTheme(for: effectiveAppearance)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Configuration

    func applyFont(_ font: NSFont, rtlFont: NSFont?) {
        self.font = font
        self.rtlFont = rtlFont
        fontVariants.removeAll()
        invalidateLayouts()

        let ctFont = font as CTFont
        var characters: [UniChar] = [0x4d]   // "M"
        var glyphs: [CGGlyph] = [0]
        CTFontGetGlyphsForCharacters(ctFont, &characters, &glyphs, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyphs, &advance, 1)

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        // Metrics are rounded to physical pixels so cell edges meet exactly.
        cellWidth = max(1, (advance.width * scale).rounded() / scale)
        ascent = CTFontGetAscent(ctFont)
        descent = CTFontGetDescent(ctFont)
        let natural = ascent + descent + CTFontGetLeading(ctFont)
        // Persian/Arabic fallback fonts are taller than Latin monospace fonts.
        lineHeight = (max(natural, font.pointSize * 1.3) * scale).rounded(.up) / scale
        updateDocumentSize()
    }

    func setDirection(smartRtl: Bool, rowRtl: Bool) {
        guard smartRtl != self.smartRtl || rowRtl != self.rowRtl else { return }
        self.smartRtl = smartRtl
        self.rowRtl = rowRtl
        invalidateLayouts()
    }

    func refreshTheme() {
        theme = Settings.shared.terminalTheme(for: effectiveAppearance)
        invalidateLayouts()
        delegate?.terminalViewThemeDidChange(self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshTheme()
    }

    func invalidateLayouts() {
        shapedRows.removeAll()
        glyphCache.removeAll()
        colorCache.removeAll()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged {
            shapedRows.removeAll()
            needsDisplay = true
        }
    }

    // MARK: - Snapshots

    func present(_ snapshot: TerminalSnapshot) {
        let followOutput = isScrolledToBottom
        var trimmed = 0

        if let previous = self.snapshot {
            trimmed = snapshot.scrollbackStartIndex - previous.scrollbackStartIndex
            if previous.modes.alternateScreen != snapshot.modes.alternateScreen {
                clearSelectionState()
                shapedRows.removeAll()
            } else if trimmed != 0 || previous.scrollbackCount != snapshot.scrollbackCount {
                shiftSelection(by: trimmed)
                // Row indices moved: cached rows would describe other lines.
                if trimmed != 0 { shapedRows.removeAll() }
            }
        }

        self.snapshot = snapshot
        updateDocumentSize()

        if followOutput {
            scrollToBottom()
        } else if trimmed > 0, let clip = enclosingScrollView?.contentView {
            let origin = NSPoint(x: 0, y: max(0, clip.bounds.minY - CGFloat(trimmed) * lineHeight))
            clip.scroll(to: origin)
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
        needsDisplay = true
    }

    func reset() {
        snapshot = nil
        clearSelectionState()
        invalidateLayouts()
    }

    func updateDocumentSize() {
        guard let clip = enclosingScrollView?.contentView else { return }
        let lines = CGFloat(snapshot?.lineCount ?? 0)
        let height = max(clip.bounds.height, lines * lineHeight)
        if frame.height != height || frame.width != clip.bounds.width {
            setFrameSize(NSSize(width: clip.bounds.width, height: height))
        }
    }

    var isScrolledToBottom: Bool {
        guard let clip = enclosingScrollView?.contentView else { return true }
        return clip.bounds.maxY >= frame.height - lineHeight / 2
    }

    func scrollToBottom() {
        guard let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        let y = max(0, frame.height - clip.bounds.height)
        if clip.bounds.minY != y {
            clip.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    // MARK: - Layout

    private struct ShapedRow {
        var layout: RowLayout
        var rtlLines: [Int: (line: CTLine, scale: CGFloat)]
        var links: [DetectedLink]
    }

    private struct GlyphKey: Hashable {
        var text: String
        var variant: Int
        var color: TerminalColor
    }

    private func shapedRow(_ index: Int) -> ShapedRow? {
        guard let snapshot, index >= 0, index < snapshot.lineCount else { return nil }
        let line = snapshot.line(index)
        if let cached = shapedRows[index], cached.layout.line.hasSameContent(as: line) { return cached }

        var layout = RowLayout(
            line: line,
            smartRtl: smartRtl,
            rowRtl: rowRtl,
            preserveTerminalGrid: snapshot.modes.alternateScreen,
            cellWidth: Double(cellWidth),
            viewportWidth: Double(bounds.width - 2 * Self.inset))
        let links = LinkDetector.links(in: layout.text)
        var rtlLines: [Int: (line: CTLine, scale: CGFloat)] = [:]

        for (glyphIndex, glyph) in layout.glyphs.enumerated()
        where glyph.isRightToLeft && !glyph.text.allSatisfy(\.isWhitespace) {
            let text = attributedText(glyph.text, start: glyph.start, layout: layout, links: links, rtl: true)
            let ctLine = CTLineCreateWithAttributedString(text as CFAttributedString)
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
            let scale = width > 0 ? CGFloat(glyph.width) / width : 1
            rtlLines[glyphIndex] = (ctLine, scale)

            // Selection, links, cursor and mouse hit testing use the shaped
            // glyph positions, including ligatures and variable-width letters.
            for cellIndex in layout.cells.indices {
                let cell = layout.cells[cellIndex]
                guard cell.start >= glyph.start, cell.start < glyph.start + (glyph.text as NSString).length else { continue }
                let local = cell.start - glyph.start
                let a = CTLineGetOffsetForStringIndex(ctLine, local, nil)
                let b = CTLineGetOffsetForStringIndex(ctLine, local + cell.length, nil)
                let shapedLeft = min(a, b)
                let shapedWidth = abs(b - a)
                guard shapedWidth > 0 else { continue }
                layout.cells[cellIndex].x = glyph.x + Double(shapedLeft * scale)
                layout.cells[cellIndex].width = Double(shapedWidth * scale)
            }
        }

        let shaped = ShapedRow(layout: layout, rtlLines: rtlLines, links: links)
        shapedRows[index] = shaped
        return shaped
    }

    private func fontVariant(bold: Bool, italic: Bool, rtl: Bool) -> CTFont {
        let key = (bold ? 1 : 0) | (italic ? 2 : 0) | (rtl ? 4 : 0)
        if let cached = fontVariants[key] { return cached }
        let base = (rtl ? rtlFont ?? font : font) as CTFont
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        let variant = traits.isEmpty
            ? base
            : CTFontCreateCopyWithSymbolicTraits(base, 0, nil, traits, traits) ?? base
        fontVariants[key] = variant
        return variant
    }

    private func cgColor(_ color: TerminalColor) -> CGColor {
        if let cached = colorCache[color] { return cached }
        if colorCache.count > 1024 { colorCache.removeAll() }
        let value = CGColor(
            srgbRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255, alpha: 1)
        colorCache[color] = value
        return value
    }

    private var linkColor: TerminalColor {
        theme == .light ? TerminalColor(9, 105, 218) : TerminalColor(100, 149, 237)
    }

    private func attributedText(
        _ text: String, start: Int, layout: RowLayout, links: [DetectedLink], rtl: Bool
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text)
        let length = result.length
        let foregroundKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        var index = 0

        while index < length {
            let style = layout.style(at: start + index)
            var end = index + 1
            while end < length && layout.style(at: start + end) == style { end += 1 }
            result.addAttributes([
                .font: fontVariant(bold: style.bold, italic: style.italic, rtl: rtl),
                foregroundKey: cgColor(theme.colors(for: style).foreground)
            ], range: NSRange(location: index, length: end - index))
            index = end
        }

        for link in links {
            let from = max(start, link.start)
            let to = min(start + length, link.start + link.length)
            guard to > from else { continue }
            result.addAttribute(foregroundKey, value: cgColor(linkColor),
                                range: NSRange(location: from - start, length: to - from))
        }
        return result
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(cgColor(theme.defaultBackground))
        context.fill(dirtyRect)
        guard let snapshot, snapshot.lineCount > 0 else { return }

        let first = max(0, Int(dirtyRect.minY / lineHeight))
        let last = min(snapshot.lineCount, Int((dirtyRect.maxY / lineHeight).rounded(.up)) + 1)
        guard first < last else { return }

        // Drop cached rows far outside the viewport.
        if shapedRows.count > 4 * (last - first) + 64 {
            shapedRows = shapedRows.filter { $0.key >= first - 200 && $0.key < last + 200 }
        }

        let rows = (first..<last).compactMap { index in shapedRow(index).map { (index, $0) } }

        // Backgrounds first, so tall Persian glyphs are not cut by the next row.
        for (index, row) in rows { drawBackground(row, y: CGFloat(index) * lineHeight, in: context) }
        for (index, row) in rows { drawText(row, y: CGFloat(index) * lineHeight, in: context) }
        for (index, row) in rows { drawSelection(row, index: index, in: context) }
        drawCursor(in: context)
    }

    private func drawBackground(_ row: ShapedRow, y: CGFloat, in context: CGContext) {
        // Merge adjacent backgrounds: fewer fills and no fractional seams.
        let cells = row.layout.cells.sorted { $0.x < $1.x }
        var index = 0
        while index < cells.count {
            let cell = cells[index]
            let color = theme.colors(for: cell.style).background
            var right = cell.x + cell.width
            index += 1
            while index < cells.count && abs(cells[index].x - right) < 0.01 &&
                    theme.colors(for: cells[index].style).background == color {
                right = cells[index].x + cells[index].width
                index += 1
            }
            guard color != theme.defaultBackground else { continue }
            context.setFillColor(cgColor(color))
            context.fill(CGRect(x: Self.inset + cell.x, y: y, width: right - cell.x, height: lineHeight))
        }
    }

    private func drawText(_ row: ShapedRow, y: CGFloat, in context: CGContext) {
        let baseline = y + ((lineHeight - ascent - descent) / 2).rounded() + ascent

        for (glyphIndex, glyph) in row.layout.glyphs.enumerated() {
            if glyph.style.hidden { continue }
            let x = Self.inset + CGFloat(glyph.x)

            if let rtl = row.rtlLines[glyphIndex] {
                context.saveGState()
                context.translateBy(x: x, y: baseline)
                context.scaleBy(x: rtl.scale, y: 1)
                context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                context.textPosition = .zero
                CTLineDraw(rtl.line, context)
                context.restoreGState()
                continue
            }

            if glyph.isRightToLeft || glyph.text == " " { continue }
            let foreground = theme.colors(for: glyph.style).foreground
            if drawBlock(glyph, x: x, y: y, in: context) || drawBox(glyph, x: x, y: y, foreground: foreground, in: context) {
                continue
            }

            let isLink = row.links.contains { $0.contains(glyph.start) }
            let color = isLink ? linkColor : foreground
            let key = GlyphKey(
                text: glyph.text,
                variant: (glyph.style.bold ? 1 : 0) | (glyph.style.italic ? 2 : 0),
                color: color)
            let line: CTLine
            if let cached = glyphCache[key] {
                line = cached
            } else {
                let attributed = NSAttributedString(string: glyph.text, attributes: [
                    .font: fontVariant(bold: glyph.style.bold, italic: glyph.style.italic, rtl: false),
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor(color)
                ])
                line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
                if glyphCache.count > 4096 { glyphCache.removeAll() }
                glyphCache[key] = line
            }
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line, context)
        }

        // CoreText does not draw decorations; draw them per cell.
        for cell in row.layout.cells where cell.width > 0 {
            let isLink = row.links.contains { $0.contains(cell.start) }
            guard cell.style.underline || cell.style.strikethrough || isLink, !cell.style.hidden else { continue }
            let color = isLink ? linkColor : theme.colors(for: cell.style).foreground
            context.setFillColor(cgColor(color))
            let x = Self.inset + CGFloat(cell.x)
            if cell.style.underline || isLink {
                context.fill(CGRect(x: x, y: baseline + 2, width: CGFloat(cell.width), height: 1))
            }
            if cell.style.strikethrough {
                context.fill(CGRect(x: x, y: (baseline - ascent * 0.3).rounded(), width: CGFloat(cell.width), height: 1))
            }
        }
    }

    private func drawSelection(_ row: ShapedRow, index: Int, in context: CGContext) {
        guard hasSelection, let (start, end) = selectionRange,
              index >= start.row, index <= end.row else { return }
        context.setFillColor(CGColor(srgbRed: 70 / 255, green: 125 / 255, blue: 200 / 255, alpha: 0.4))
        let y = CGFloat(index) * lineHeight
        for cell in row.layout.cells {
            if index == start.row && cell.start + cell.length <= start.offset { continue }
            if index == end.row && cell.start >= end.offset { continue }
            context.fill(CGRect(x: Self.inset + CGFloat(cell.x), y: y, width: CGFloat(cell.width), height: lineHeight))
        }
    }

    private func cursorRect() -> CGRect? {
        guard let snapshot, snapshot.cursorVisible else { return nil }
        let row = snapshot.scrollbackCount + snapshot.cursorRow
        guard let shaped = shapedRow(row) else { return nil }
        let cell = shaped.layout.cell(atColumn: snapshot.cursorColumn)
        let x = cell.map { CGFloat($0.x) } ?? CGFloat(snapshot.cursorColumn) * cellWidth
        let width = max(cellWidth, cell.map { CGFloat($0.width) } ?? cellWidth)
        return CGRect(x: Self.inset + x, y: CGFloat(row) * lineHeight, width: width, height: lineHeight)
    }

    private func drawCursor(in context: CGContext) {
        guard let rect = cursorRect() else { return }
        let light = theme == .light
        if let marked, marked.length > 0 {
            // IME composition is shown at the cursor.
            let text = NSAttributedString(string: marked.string, attributes: [
                .font: font,
                .foregroundColor: NSColor(cgColor: cgColor(theme.defaultForeground)) ?? .textColor,
                .backgroundColor: NSColor(cgColor: cgColor(theme.defaultBackground)) ?? .textBackgroundColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ])
            text.draw(at: NSPoint(x: rect.minX, y: rect.minY))
            return
        }
        let border = light ? CGColor(srgbRed: 110 / 255, green: 119 / 255, blue: 129 / 255, alpha: 1)
            : CGColor(srgbRed: 0.83, green: 0.83, blue: 0.83, alpha: 1)
        if isWindowKey {
            let fill = cgColor(theme.defaultForeground).copy(alpha: 0.35) ?? border
            context.setFillColor(fill)
            context.fill(rect)
        }
        context.setStrokeColor(border)
        context.setLineWidth(1)
        context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
    }

    private func drawBlock(_ glyph: LayoutGlyph, x: CGFloat, y: CGFloat, in context: CGContext) -> Bool {
        guard glyph.text.unicodeScalars.count == 1, let scalar = glyph.text.unicodeScalars.first,
              (0x2580...0x259f).contains(scalar.value) else { return false }
        let code = Int(scalar.value)
        let colors = theme.colors(for: glyph.style)
        var foreground = colors.foreground
        let background = colors.background
        let width = CGFloat(glyph.width)

        func fill(_ left: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat) {
            context.setFillColor(cgColor(foreground))
            context.fill(CGRect(x: x + left * width, y: y + top * lineHeight, width: w * width, height: h * lineHeight))
        }

        switch code {
        case 0x2580: fill(0, 0, 1, 0.5)
        case 0x2581...0x2588:
            let height = CGFloat(code - 0x2580) / 8
            fill(0, 1 - height, 1, height)
        case 0x2589...0x258f: fill(0, 0, CGFloat(0x2590 - code) / 8, 1)
        case 0x2590: fill(0.5, 0, 0.5, 1)
        case 0x2591...0x2593:
            // Shades blend foreground into background.
            let amount = Double(code - 0x2590) / 4
            func blend(_ fg: UInt8, _ bg: UInt8) -> UInt8 {
                UInt8((Double(fg) * amount + Double(bg) * (1 - amount)).rounded())
            }
            foreground = TerminalColor(
                blend(foreground.red, background.red),
                blend(foreground.green, background.green),
                blend(foreground.blue, background.blue))
            fill(0, 0, 1, 1)
        case 0x2594: fill(0, 0, 1, 0.125)
        case 0x2595: fill(0.875, 0, 0.125, 1)
        default:
            // Quadrants: upper-left, upper-right, lower-left, lower-right.
            let masks = [0x2596: 4, 0x2597: 8, 0x2598: 1, 0x2599: 13, 0x259a: 9,
                         0x259b: 7, 0x259c: 11, 0x259d: 2, 0x259e: 6, 0x259f: 14]
            let mask = masks[code] ?? 0
            for quadrant in 0..<4 where mask & (1 << quadrant) != 0 {
                fill(CGFloat(quadrant % 2) * 0.5, CGFloat(quadrant / 2) * 0.5, 0.5, 0.5)
            }
        }
        return true
    }

    private static let boxEdges: [String: Int] = {
        var edges: [String: Int] = [:]
        let groups: [(String, Int)] = [
            ("─━═", 3), ("│┃║", 12), ("┌┏╔╭", 10), ("┐┓╗╮", 9), ("└┗╚╰", 6), ("┘┛╝╯", 5),
            ("├┣╠", 14), ("┤┫╣", 13), ("┬┳╦", 11), ("┴┻╩", 7), ("┼╋╬", 15)
        ]
        for (characters, mask) in groups {
            for character in characters { edges[String(character)] = mask }
        }
        return edges
    }()

    private func drawBox(_ glyph: LayoutGlyph, x: CGFloat, y: CGFloat, foreground: TerminalColor, in context: CGContext) -> Bool {
        // Edges meet at cell boundaries regardless of font metrics.
        guard let edges = Self.boxEdges[glyph.text] else { return false }
        let heavy = "━┃┏┓┗┛┣┫┳┻╋".contains(glyph.text)
        let double = "═║╔╗╚╝╠╣╦╩╬".contains(glyph.text)
        let width = CGFloat(glyph.width)
        let middleX = (x + width / 2).rounded(.down) + 0.5
        let middleY = (y + lineHeight / 2).rounded(.down) + 0.5

        context.setStrokeColor(cgColor(foreground))
        context.setLineWidth(heavy ? 2 : 1)
        context.setLineCap(.square)
        for offset in double ? [-1.5, 1.5] as [CGFloat] : [0] {
            if edges & 1 != 0 { context.strokeLineSegments(between: [CGPoint(x: x, y: middleY + offset), CGPoint(x: middleX + offset, y: middleY + offset)]) }
            if edges & 2 != 0 { context.strokeLineSegments(between: [CGPoint(x: middleX + offset, y: middleY + offset), CGPoint(x: x + width, y: middleY + offset)]) }
            if edges & 4 != 0 { context.strokeLineSegments(between: [CGPoint(x: middleX + offset, y: y), CGPoint(x: middleX + offset, y: middleY + offset)]) }
            if edges & 8 != 0 { context.strokeLineSegments(between: [CGPoint(x: middleX + offset, y: middleY + offset), CGPoint(x: middleX + offset, y: y + lineHeight)]) }
        }
        return true
    }

    // MARK: - Selection

    private struct TextPosition: Equatable, Comparable {
        var row: Int
        var offset: Int

        static func < (lhs: TextPosition, rhs: TextPosition) -> Bool {
            lhs.row < rhs.row || (lhs.row == rhs.row && lhs.offset < rhs.offset)
        }
    }

    private var selectionRange: (TextPosition, TextPosition)? {
        guard let anchor, let selectionEnd else { return nil }
        return anchor <= selectionEnd ? (anchor, selectionEnd) : (selectionEnd, anchor)
    }

    private func clearSelectionState() {
        anchor = nil
        selectionEnd = nil
    }

    func clearSelection() {
        clearSelectionState()
        needsDisplay = true
    }

    private func shiftSelection(by trimmed: Int) {
        guard trimmed != 0, var start = anchor, var end = selectionEnd else { return }
        start.row -= trimmed
        end.row -= trimmed
        if start.row < 0 || end.row < 0 {
            clearSelectionState()
        } else {
            anchor = start
            selectionEnd = end
        }
    }

    private func textPosition(at point: NSPoint) -> TextPosition? {
        guard let snapshot, snapshot.lineCount > 0 else { return nil }
        let row = min(max(0, Int(point.y / lineHeight)), snapshot.lineCount - 1)
        guard let shaped = shapedRow(row) else { return nil }
        return TextPosition(row: row, offset: shaped.layout.offset(atX: Double(point.x - Self.inset)))
    }

    var selectedText: String {
        guard hasSelection, let snapshot, let (start, end) = selectionRange,
              start.row < snapshot.lineCount else { return "" }
        var lines: [String] = []
        for row in start.row...min(end.row, snapshot.lineCount - 1) {
            let text = snapshot.line(row).text as NSString
            let from = row == start.row ? min(start.offset, text.length) : 0
            let to = row == end.row ? min(end.offset, text.length) : text.length
            var line = text.substring(with: NSRange(location: from, length: max(0, to - from)))
            while line.hasSuffix(" ") { line.removeLast() }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private func selectWord(at position: TextPosition) {
        guard let snapshot else { return }
        let text = snapshot.line(position.row).text as NSString
        let whitespace = CharacterSet.whitespaces
        func isSpace(_ index: Int) -> Bool {
            guard let scalar = Unicode.Scalar(text.character(at: index)) else { return false }
            return whitespace.contains(scalar)
        }
        var start = min(position.offset, text.length)
        var end = start
        while start > 0 && !isSpace(start - 1) { start -= 1 }
        while end < text.length && !isSpace(end) { end += 1 }
        anchor = TextPosition(row: position.row, offset: start)
        selectionEnd = TextPosition(row: position.row, offset: end)
    }

    @objc override func selectAll(_ sender: Any?) {
        guard let snapshot, snapshot.lineCount > 0 else { return }
        anchor = TextPosition(row: 0, offset: 0)
        let last = snapshot.lineCount - 1
        selectionEnd = TextPosition(row: last, offset: (snapshot.line(last).text as NSString).length)
        needsDisplay = true
    }

    @objc func copy(_ sender: Any?) {
        guard hasSelection else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(selectedText, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            sendPaste(urls.map { KeyEncoder.shellEscaped($0.path) }.joined(separator: " "))
        } else if let text = pasteboard.string(forType: .string) {
            sendPaste(text)
        } else if let image = NSImage(pasteboard: pasteboard), let path = Self.saveTemporaryImage(image) {
            // Clipboard images are pasted as a file path, for CLI agents.
            sendPaste(KeyEncoder.shellEscaped(path))
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)):
            return hasSelection
        case #selector(paste(_:)):
            let types = NSPasteboard.general.types ?? []
            return types.contains(.string) || types.contains(.fileURL) || types.contains(.tiff) || types.contains(.png)
        default:
            return true
        }
    }

    private func sendPaste(_ text: String) {
        guard !text.isEmpty else { return }
        send(KeyEncoder.paste(text, bracketed: modes.bracketedPaste))
    }

    private static func saveTemporaryImage(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RtlTerminal-clipboard-\(UUID().uuidString).png")
        guard (try? png.write(to: url)) != nil else { return nil }
        temporaryFiles.append(url)
        return url.path
    }

    private func send(_ text: String) {
        delegate?.terminalView(self, send: text)
    }

    // MARK: - Keyboard

    private static let specialKeys: [UInt16: TerminalKey] = [
        36: .enter, 76: .enter, 48: .tab, 49: .space, 51: .backspace, 53: .escape,
        114: .insert, 117: .delete, 115: .home, 119: .end, 116: .pageUp, 121: .pageDown,
        123: .left, 124: .right, 125: .down, 126: .up,
        122: .function(1), 120: .function(2), 99: .function(3), 118: .function(4),
        96: .function(5), 97: .function(6), 98: .function(7), 100: .function(8),
        101: .function(9), 109: .function(10), 103: .function(11), 111: .function(12)
    ]

    /// US-layout characters by key code, so Ctrl and Meta shortcuts work
    /// while a Persian or Arabic keyboard layout is active.
    private static let latinKeys: [UInt16: Character] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
        11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
        29: "0", 30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l", 38: "j",
        39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "n", 46: "m", 47: ".", 50: "`"
    ]

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
        NSCursor.setHiddenUntilMouseMoves(true)

        if hasMarkedText() {
            interpretKeyEvents([event])
            return
        }

        var modifiers: KeyModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        let meta = flags.contains(.option) && optionAsMeta
        if meta { modifiers.insert(.alt) }

        if let key = Self.specialKeys[event.keyCode],
           // Option+arrow moves by word in macOS terminals.
           let sequence = flags.contains(.option) && !optionAsMeta && (key == .left || key == .right)
            ? "\u{1b}" + (key == .left ? "b" : "f")
            : KeyEncoder.sequence(for: key, modifiers: modifiers, applicationCursorKeys: modes.applicationCursorKeys) {
            typed(sequence)
            return
        }

        if flags.contains(.control) {
            let character = asciiCharacter(for: event)
            if let character, let control = KeyEncoder.controlCharacter(for: character) {
                typed(meta ? "\u{1b}" + control : control)
                return
            }
        }

        if meta, let character = asciiCharacter(for: event) ?? event.charactersIgnoringModifiers?.first {
            let text = flags.contains(.shift) ? String(character).uppercased() : String(character)
            typed("\u{1b}" + text)
            return
        }

        interpretKeyEvents([event])
    }

    private func asciiCharacter(for event: NSEvent) -> Character? {
        if let character = event.charactersIgnoringModifiers?.lowercased().first, character.isASCII {
            return character
        }
        return Self.latinKeys[event.keyCode]
    }

    private func typed(_ text: String) {
        clearSelection()
        scrollToBottom()
        send(text)
    }

    override func doCommand(by selector: Selector) {
        // Special keys are encoded in keyDown; these arrive only from input methods.
        switch selector {
        case #selector(insertNewline(_:)): typed("\r")
        case #selector(insertTab(_:)): typed("\t")
        case #selector(deleteBackward(_:)): typed("\u{7f}")
        case #selector(cancelOperation(_:)): typed("\u{1b}")
        default: break
        }
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        marked = nil
        guard !text.isEmpty else { return }
        typed(text)
        needsDisplay = true
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let attributed = string as? NSAttributedString {
            marked = attributed
        } else if let text = string as? String {
            marked = NSAttributedString(string: text)
        }
        if marked?.length == 0 { marked = nil }
        needsDisplay = true
    }

    func unmarkText() {
        marked = nil
        needsDisplay = true
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func markedRange() -> NSRange {
        guard let marked else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: marked.length)
    }

    func hasMarkedText() -> Bool { (marked?.length ?? 0) > 0 }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let rect = cursorRect() ?? NSRect(x: Self.inset, y: 0, width: cellWidth, height: lineHeight)
        guard let window else { return rect }
        return window.convertToScreen(convert(rect, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.iBeam.set()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) && link(at: point) != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.iBeam.set()
        }
        if modes.mouseTrackingMode == 1003 { _ = reportMouse(event, button: 35, released: false, motion: true) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)

        if event.modifierFlags.contains(.command), let url = link(at: point) {
            NSWorkspace.shared.open(url)
            return
        }
        if reportMouse(event, button: 0, released: false) {
            reportedButton = 0
            return
        }
        guard let position = textPosition(at: point) else { return }

        switch event.clickCount {
        case 2:
            selectWord(at: position)
        case 3:
            anchor = TextPosition(row: position.row, offset: 0)
            selectionEnd = TextPosition(row: position.row, offset: ((snapshot?.line(position.row).text ?? "") as NSString).length)
        default:
            if event.modifierFlags.contains(.shift), anchor != nil {
                selectionEnd = position
            } else {
                anchor = position
                selectionEnd = position
            }
        }
        dragging = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if let button = reportedButton {
            if modes.mouseTrackingMode >= 1002 { _ = reportMouse(event, button: button + 32, released: false, motion: true) }
            return
        }
        guard dragging else { return }
        autoscroll(with: event)
        if let position = textPosition(at: convert(event.locationInWindow, from: nil)) {
            selectionEnd = position
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let button = reportedButton {
            _ = reportMouse(event, button: button, released: true, force: true)
            reportedButton = nil
            return
        }
        dragging = false
    }

    override func rightMouseDown(with event: NSEvent) {
        if reportMouse(event, button: 2, released: false) {
            reportedButton = 2
            return
        }
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        if reportedButton == 2 {
            _ = reportMouse(event, button: 2, released: true, force: true)
            reportedButton = nil
            return
        }
        super.rightMouseUp(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        if reportMouse(event, button: 1, released: false) { reportedButton = 1 }
    }

    override func otherMouseUp(with event: NSEvent) {
        if reportedButton == 1 {
            _ = reportMouse(event, button: 1, released: true, force: true)
            reportedButton = nil
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear Scrollback", action: Selector(("clearScrollback:")), keyEquivalent: "")
        if let url = link(at: convert(event.locationInWindow, from: nil)) {
            menu.insertItem(.separator(), at: 0)
            let open = NSMenuItem(title: "Open Link", action: #selector(openLink(_:)), keyEquivalent: "")
            open.representedObject = url
            open.target = self
            menu.insertItem(open, at: 0)
        }
        return menu
    }

    @objc private func openLink(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.open(url) }
    }

    override func scrollWheel(with event: NSEvent) {
        let modes = self.modes
        let reportsMouse = modes.mouseTrackingMode > 0 && modes.sgrMouse && !event.modifierFlags.contains(.shift)
        guard reportsMouse || modes.alternateScreen else {
            super.scrollWheel(with: event)
            return
        }

        // Applications in the alternate screen scroll themselves.
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / lineHeight : event.scrollingDeltaY
        scrollAccumulator += delta
        let lines = Int(scrollAccumulator.rounded(.towardZero))
        guard lines != 0 else { return }
        scrollAccumulator -= CGFloat(lines)

        for _ in 0..<min(abs(lines), 10) {
            if reportsMouse {
                _ = reportMouse(event, button: lines > 0 ? 64 : 65, released: false, force: true)
            } else if let sequence = KeyEncoder.sequence(
                for: lines > 0 ? .up : .down, modifiers: [], applicationCursorKeys: modes.applicationCursorKeys) {
                send(sequence)
            }
        }
    }

    /// Sends an SGR mouse report when the application asked for the mouse.
    /// Shift bypasses reporting so text can still be selected.
    private func reportMouse(_ event: NSEvent, button: Int, released: Bool, motion: Bool = false, force: Bool = false) -> Bool {
        let modes = self.modes
        guard modes.mouseTrackingMode > 0, modes.sgrMouse else { return false }
        guard force || !event.modifierFlags.contains(.shift) else { return false }
        guard let cell = gridCell(at: convert(event.locationInWindow, from: nil)) else { return force }
        if motion, let last = lastReportedCell, last == cell { return true }
        lastReportedCell = cell

        var modifiers: KeyModifiers = []
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.alt) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        send(KeyEncoder.sgrMouse(button: button, x: cell.x, y: cell.y, released: released, modifiers: modifiers))
        return true
    }

    /// 1-based terminal grid cell under a point, in logical (PTY) columns.
    private func gridCell(at point: NSPoint) -> (x: Int, y: Int)? {
        guard let snapshot else { return nil }
        let row = Int(point.y / lineHeight)
        let screenRow = row - snapshot.scrollbackCount
        guard screenRow >= 0 else { return nil }
        guard let shaped = shapedRow(row) else {
            return (max(0, Int((point.x - Self.inset) / cellWidth)) + 1, screenRow + 1)
        }
        let column = shaped.layout.logicalColumn(atX: Double(point.x - Self.inset), cellWidth: Double(cellWidth))
        return (max(0, column) + 1, screenRow + 1)
    }

    private func link(at point: NSPoint) -> URL? {
        guard let snapshot else { return nil }
        let row = Int(point.y / lineHeight)
        guard row >= 0, row < snapshot.lineCount, let shaped = shapedRow(row),
              let cell = shaped.layout.cell(atX: Double(point.x - Self.inset)), !cell.style.hidden
        else { return nil }
        return shaped.links.first { $0.contains(cell.start) }?.url
    }

    // MARK: - Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty
        else { return false }
        // Like Terminal.app: dropped files become quoted paths.
        sendPaste(urls.map { KeyEncoder.shellEscaped($0.path) }.joined(separator: " ") + " ")
        window?.makeFirstResponder(self)
        return true
    }
}
#endif
