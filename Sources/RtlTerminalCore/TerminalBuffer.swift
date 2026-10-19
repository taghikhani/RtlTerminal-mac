import Foundation

/// VT/xterm screen model: parses PTY output and keeps the screen grid plus
/// scrollback. Thread safe: output is fed from the PTY reader thread while
/// the UI takes snapshots on the main thread.
public final class TerminalBuffer: @unchecked Sendable {
    public static let supportedHistorySizes = [2000, 5000, 10000]
    public static let defaultHistorySize = 2000

    public static let ansiColors: [TerminalColor] = [
        TerminalColor(12, 12, 12),
        TerminalColor(197, 15, 31),
        TerminalColor(19, 161, 14),
        TerminalColor(193, 156, 0),
        TerminalColor(0, 55, 218),
        TerminalColor(136, 23, 152),
        TerminalColor(58, 150, 221),
        TerminalColor(204, 204, 204),
        TerminalColor(118, 118, 118),
        TerminalColor(231, 72, 86),
        TerminalColor(22, 198, 12),
        TerminalColor(249, 241, 165),
        TerminalColor(59, 120, 255),
        TerminalColor(180, 0, 158),
        TerminalColor(97, 214, 214),
        TerminalColor(242, 242, 242)
    ]

    /// Reported to applications that query the default colors (OSC 10/11/12).
    public var defaultForeground = TerminalColor(230, 230, 230)
    public var defaultBackground = TerminalColor(12, 12, 12)
    public var versionString = "1.0"

    private let lock = NSLock()
    private var decoder = Utf8StreamDecoder()
    private var csi = ""
    private var osc = ""
    private var dcs = ""
    private var scrollback: [TerminalLine] = []
    private var pendingResponses: [String] = []
    private var maximumScrollbackRows: Int
    private var scrollbackStartIndex = 0
    private var cells: [Cell]
    private var snapshotCells: [Cell] = []
    private var snapshotLines: [TerminalLine?] = []
    private var wrappedFromPrevious: [Bool]
    private var columns: Int
    private var rows: Int
    private var cursorColumn = 0
    private var cursorRow = 0
    private var savedColumn = 0
    private var savedRow = 0
    private var scrollTop = 0
    private var scrollBottom: Int
    private var revision = 0
    private var wrapPending = false
    private var alternateScreenActive = false
    private var cursorVisible = true
    private var applicationCursorKeys = false
    private var autoWrapMode = true
    private var originMode = false
    private var bracketedPaste = false
    private var focusReporting = false
    private var mouseTrackingMode = 0
    private var sgrMouse = false
    private var synchronizedOutput = false
    private var joinNextCharacter = false
    private var regionalIndicatorPending = false
    private var title: String?
    private var state = ParserState.normal
    private var currentStyle = TerminalStyle()
    private var savedMainScreen: SavedScreen?

    public init(columns: Int, rows: Int, maximumScrollbackRows: Int = TerminalBuffer.defaultHistorySize) {
        self.maximumScrollbackRows = Self.normalizeHistorySize(maximumScrollbackRows)
        self.columns = max(10, columns)
        self.rows = max(5, rows)
        scrollBottom = self.rows - 1
        cells = Array(repeating: Cell.blank, count: self.rows * self.columns)
        wrappedFromPrevious = Array(repeating: false, count: self.rows)
    }

    public var gridSize: (columns: Int, rows: Int) {
        lock.lock(); defer { lock.unlock() }
        return (columns, rows)
    }

    public func setMaximumScrollbackRows(_ maximumRows: Int) {
        lock.lock(); defer { lock.unlock() }
        maximumScrollbackRows = Self.normalizeHistorySize(maximumRows)
        trimScrollback()
        revision += 1
    }

    /// Feeds raw PTY output. Returns replies (device status, color queries…)
    /// that must be written back to the PTY.
    @discardableResult
    public func process(bytes: UnsafeBufferPointer<UInt8>) -> [String] {
        lock.lock(); defer { lock.unlock() }
        for scalar in decoder.decode(bytes) { processScalar(scalar) }
        return takeResponses()
    }

    @discardableResult
    public func process(_ text: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        for scalar in text.unicodeScalars { processScalar(scalar) }
        return takeResponses()
    }

    public func resize(columns newColumns: Int, rows newRows: Int) {
        lock.lock(); defer { lock.unlock() }
        let newColumns = max(10, newColumns)
        let newRows = max(5, newRows)
        guard newColumns != columns || newRows != rows else { return }

        cells = Self.resizeCells(cells, columns: columns, rows: rows, newColumns: newColumns, newRows: newRows)
        wrappedFromPrevious = Self.resizeWrapState(wrappedFromPrevious, newRows)

        if var saved = savedMainScreen {
            saved.cells = Self.resizeCells(saved.cells, columns: columns, rows: rows, newColumns: newColumns, newRows: newRows)
            saved.wrappedFromPrevious = Self.resizeWrapState(saved.wrappedFromPrevious, newRows)
            saved.cursorRow = clamp(saved.cursorRow, 0, newRows - 1)
            saved.cursorColumn = clamp(saved.cursorColumn, 0, newColumns - 1)
            saved.scrollTop = 0
            saved.scrollBottom = newRows - 1
            savedMainScreen = saved
        }

        columns = newColumns
        rows = newRows
        scrollTop = 0
        scrollBottom = newRows - 1
        cursorRow = clamp(cursorRow, 0, newRows - 1)
        cursorColumn = clamp(cursorColumn, 0, newColumns - 1)
        wrapPending = false
        revision += 1
    }

    /// Clears retained history (Cmd+K) without touching the visible screen.
    public func clearScrollback() {
        lock.lock(); defer { lock.unlock() }
        guard !scrollback.isEmpty else { return }
        scrollbackStartIndex += scrollback.count
        scrollback.removeAll()
        revision += 1
    }

    /// Turns off mouse and focus reporting. Used when the shell is back in
    /// the foreground but a program that enabled them exited without
    /// restoring them (crash, Ctrl+C, dropped SSH connection), which would
    /// otherwise type mouse reports into the prompt. Returns true if anything changed.
    @discardableResult
    public func resetMouseReporting() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard mouseTrackingMode != 0 || sgrMouse || focusReporting else { return false }
        mouseTrackingMode = 0
        sgrMouse = false
        focusReporting = false
        revision += 1
        return true
    }

    public var currentRevision: Int {
        lock.lock(); defer { lock.unlock() }
        return revision
    }

    public func snapshot() -> TerminalSnapshot {
        lock.lock(); defer { lock.unlock() }
        return createSnapshot()
    }

    // MARK: - Parser

    private func processScalar(_ scalar: Unicode.Scalar) {
        revision += 1

        switch state {
        case .escape:
            processEscape(scalar)
            return
        case .csi:
            processCsi(scalar)
            return
        case .osc:
            if scalar == "\u{07}" {
                processOsc()
                state = .normal
            } else if scalar == "\u{1b}" {
                state = .oscEscape
            } else if osc.unicodeScalars.count < 4096 {
                osc.unicodeScalars.append(scalar)
            }
            return
        case .oscEscape:
            if scalar == "\\" {
                processOsc()
                state = .normal
            } else {
                if osc.unicodeScalars.count < 4096 {
                    osc.unicodeScalars.append("\u{1b}")
                    osc.unicodeScalars.append(scalar)
                }
                state = .osc
            }
            return
        case .dcs:
            if scalar == "\u{1b}" {
                state = .dcsEscape
            } else if dcs.unicodeScalars.count < 4096 {
                dcs.unicodeScalars.append(scalar)
            }
            return
        case .dcsEscape:
            if scalar == "\\" {
                processDcs()
                state = .normal
            } else {
                if dcs.unicodeScalars.count < 4096 {
                    dcs.unicodeScalars.append("\u{1b}")
                    dcs.unicodeScalars.append(scalar)
                }
                state = .dcs
            }
            return
        case .controlString:
            if scalar == "\u{1b}" { state = .controlStringEscape }
            return
        case .controlStringEscape:
            state = scalar == "\\" ? .normal : .controlString
            return
        case .ignoreNext:
            state = .normal
            return
        case .normal:
            break
        }

        switch scalar {
        case "\u{1b}":
            resetClusterState()
            state = .escape
        case "\r":
            resetClusterState()
            cursorColumn = 0
            wrapPending = false
        case "\n", "\u{0b}", "\u{0c}":
            resetClusterState()
            wrapPending = false
            lineFeed(wrapped: false)
        case "\u{08}":
            resetClusterState()
            wrapPending = false
            cursorColumn = max(0, cursorColumn - 1)
        case "\t":
            resetClusterState()
            wrapPending = false
            cursorColumn = min(columns - 1, ((cursorColumn / 8) + 1) * 8)
        case "\u{00}", "\u{07}":
            break
        default:
            if scalar.properties.generalCategory != .control {
                writeTextElement(scalar, String(Character(scalar)))
            }
        }
    }

    private func processEscape(_ scalar: Unicode.Scalar) {
        state = .normal

        switch scalar {
        case "[":
            csi = ""
            state = .csi
        case "]":
            osc = ""
            state = .osc
        case "P":
            dcs = ""
            state = .dcs
        case "_", "^", "X":
            state = .controlString
        case "7":
            saveCursor()
        case "8":
            restoreCursor()
        case "D":
            wrapPending = false
            lineFeed(wrapped: false)
        case "E":
            wrapPending = false
            cursorColumn = 0
            lineFeed(wrapped: false)
        case "M":
            wrapPending = false
            reverseIndex()
        case "c":
            fullReset()
        case "(", ")", "#", "*", "+":
            state = .ignoreNext
        default:
            break
        }
    }

    private func processCsi(_ scalar: Unicode.Scalar) {
        if (0x40...0x7e).contains(scalar.value) {
            let parameters = csi
            csi = ""
            state = .normal
            executeCsi(Character(scalar), parameters)
            return
        }

        if csi.unicodeScalars.count < 128 { csi.unicodeScalars.append(scalar) }
    }

    private func processOsc() {
        let payload = osc
        osc = ""
        guard let separator = payload.firstIndex(of: ";"),
              let command = Int(payload[..<separator])
        else { return }

        let value = String(payload[payload.index(after: separator)...])

        switch command {
        case 0, 2:
            title = value.isEmpty ? nil : String(value.prefix(256))
        case 10 where value == "?":
            queueResponse("\u{1b}]10;\(Self.formatOscColor(defaultForeground))\u{1b}\\")
        case 11 where value == "?":
            queueResponse("\u{1b}]11;\(Self.formatOscColor(defaultBackground))\u{1b}\\")
        case 12 where value == "?":
            queueResponse("\u{1b}]12;\(Self.formatOscColor(defaultForeground))\u{1b}\\")
        case 4:
            let parts = value.split(separator: ";", omittingEmptySubsequences: false)
            if parts.count >= 2, parts[1] == "?", let index = Int(parts[0]) {
                queueResponse("\u{1b}]4;\(index);\(Self.formatOscColor(Self.color256(index)))\u{1b}\\")
            }
        default:
            break
        }
    }

    private func processDcs() {
        let payload = dcs
        dcs = ""
        guard payload.hasPrefix("+q") else { return }
        let capability = payload.dropFirst(2)
        if !capability.isEmpty { queueResponse("\u{1b}P0+r\(capability)\u{1b}\\") }
    }

    private func resetClusterState() {
        joinNextCharacter = false
        regionalIndicatorPending = false
    }

    private static func formatOscColor(_ color: TerminalColor) -> String {
        func hex(_ value: UInt8) -> String { String(format: "%02x%02x", value, value) }
        return "rgb:\(hex(color.red))/\(hex(color.green))/\(hex(color.blue))"
    }

    private func queueResponse(_ response: String) {
        pendingResponses.append(response)
    }

    private func takeResponses() -> [String] {
        guard !pendingResponses.isEmpty else { return [] }
        defer { pendingResponses.removeAll() }
        return pendingResponses
    }

    private func executeCsi(_ command: Character, _ parameterText: String) {
        let privateMode = parameterText.hasPrefix("?")
        let parameters = Self.parseParameters(parameterText)

        // Styling and capability queries do not move the cursor. In particular,
        // SGR after the last column must not make the next glyph overwrite it.
        if "ABCDEFG`dHfJKP@XLMSTr".contains(command) { wrapPending = false }

        switch command {
        case "A": cursorRow -= Self.parameter(parameters, 0, 1)
        case "B": cursorRow += Self.parameter(parameters, 0, 1)
        case "C": cursorColumn += Self.parameter(parameters, 0, 1)
        case "D": cursorColumn -= Self.parameter(parameters, 0, 1)
        case "E":
            cursorRow += Self.parameter(parameters, 0, 1)
            cursorColumn = 0
        case "F":
            cursorRow -= Self.parameter(parameters, 0, 1)
            cursorColumn = 0
        case "G", "`": cursorColumn = Self.parameter(parameters, 0, 1) - 1
        case "d": cursorRow = rowPosition(parameters, 0)
        case "H", "f":
            cursorRow = rowPosition(parameters, 0)
            cursorColumn = Self.parameter(parameters, 1, 1) - 1
        case "J": eraseDisplay(Self.parameter(parameters, 0, 0))
        case "K": eraseLine(Self.parameter(parameters, 0, 0))
        case "P": deleteCharacters(Self.parameter(parameters, 0, 1))
        case "@": insertCharacters(Self.parameter(parameters, 0, 1))
        case "X": eraseCharacters(Self.parameter(parameters, 0, 1))
        case "L": insertLines(Self.parameter(parameters, 0, 1))
        case "M": deleteLines(Self.parameter(parameters, 0, 1))
        case "S": scrollRegionUp(scrollTop, scrollBottom, Self.parameter(parameters, 0, 1))
        case "T": scrollRegionDown(scrollTop, scrollBottom, Self.parameter(parameters, 0, 1))
        case "r": setScrollRegion(parameters)
        case "m":
            // xterm modifyOtherKeys (CSI > 4 ; n m) changes input encoding
            // only; it is not SGR and must never alter text style.
            if !parameterText.hasPrefix(">") { setGraphicsRendition(parameterText) }
        case "s": saveCursor()
        case "u":
            if parameterText.trimmingCharacters(in: .whitespaces) == "?" {
                queueResponse("\u{1b}[?0u")
            } else if parameterText.hasPrefix(">") || parameterText.hasPrefix("<") || parameterText.hasPrefix("=") {
                // Kitty's keyboard protocol is deliberately not advertised.
            } else {
                restoreCursor()
            }
        case "n": deviceStatusReport(privateMode, parameters)
        case "c": deviceAttributes(parameterText)
        case "p": modeQuery(parameterText)
        case "t": windowReport(parameters)
        case "q":
            if parameterText.hasPrefix(">") {
                queueResponse("\u{1b}P>|RtlTerminal(\(versionString))\u{1b}\\")
            }
        case "h", "l":
            if privateMode { setPrivateModes(parameters, enabled: command == "h") }
        default:
            break
        }

        clampCursor()
    }

    private func rowPosition(_ parameters: [Int], _ index: Int) -> Int {
        let row = Self.parameter(parameters, index, 1) - 1
        return originMode ? scrollTop + row : row
    }

    private func deviceStatusReport(_ privateMode: Bool, _ parameters: [Int]) {
        let code = Self.parameter(parameters, 0, 0)
        if code == 5 && !privateMode {
            queueResponse("\u{1b}[0n")
            return
        }
        guard code == 6 else { return }
        let row = originMode ? cursorRow - scrollTop + 1 : cursorRow + 1
        queueResponse("\u{1b}[\(privateMode ? "?" : "")\(row);\(cursorColumn + 1)R")
    }

    private func deviceAttributes(_ parameterText: String) {
        if parameterText.hasPrefix(">") {
            queueResponse("\u{1b}[>0;10;1c")
        } else if !parameterText.hasPrefix("=") {
            queueResponse("\u{1b}[?1;2c")
        }
    }

    private func modeQuery(_ parameterText: String) {
        guard parameterText.hasPrefix("?"), parameterText.hasSuffix("$"),
              let mode = Int(parameterText.dropFirst().dropLast())
        else { return }

        let supported = [1, 6, 7, 25, 47, 1000, 1002, 1003, 1004, 1006,
                         1047, 1048, 1049, 2004, 2026].contains(mode)
        let status = supported ? (isPrivateModeEnabled(mode) ? 1 : 2) : 0
        queueResponse("\u{1b}[?\(mode);\(status)$y")
    }

    private func windowReport(_ parameters: [Int]) {
        switch Self.parameter(parameters, 0, 0) {
        case 14: queueResponse("\u{1b}[4;\(rows * 18);\(columns * 9)t")
        case 16: queueResponse("\u{1b}[6;18;9t")
        case 18: queueResponse("\u{1b}[8;\(rows);\(columns)t")
        default: break
        }
    }

    private static func parseParameters(_ text: String) -> [Int] {
        let trimmed = text.drop { "?>!=".contains($0) }
        guard !trimmed.isEmpty else { return [] }
        return trimmed.split(separator: ";", omittingEmptySubsequences: false).map {
            // Sub-parameters (colon form) only matter for SGR.
            Int($0.split(separator: ":").first ?? "") ?? 0
        }
    }

    private static func parameter(_ parameters: [Int], _ index: Int, _ defaultValue: Int) -> Int {
        index >= parameters.count || parameters[index] == 0 ? defaultValue : parameters[index]
    }

    // MARK: - Writing

    private func writeTextElement(_ scalar: Unicode.Scalar, _ text: String) {
        if joinNextCharacter {
            appendCombiningCharacter(text)
            joinNextCharacter = false
            regionalIndicatorPending = false
            return
        }

        if scalar.value == 0x200d {
            appendCombiningCharacter(text)
            joinNextCharacter = true
            return
        }

        if CellWidth.isRegionalIndicator(scalar.value) {
            if regionalIndicatorPending {
                appendCombiningCharacter(text)
                regionalIndicatorPending = false
                return
            }
            regionalIndicatorPending = true
        } else {
            regionalIndicatorPending = false
        }

        let width = CellWidth.of(scalar)
        if width == 0 {
            appendCombiningCharacter(text)
            return
        }

        if wrapPending {
            if autoWrapMode {
                cursorColumn = 0
                lineFeed(wrapped: true)
            }
            wrapPending = false
        }

        if width == 2 && cursorColumn == columns - 1 {
            cursorColumn = 0
            lineFeed(wrapped: true)
        }

        // A redraw may replace only one half of an existing wide glyph. Clear
        // any wide character crossing either edge of the cells being written.
        normalizeWideCharacterBoundary(cursorRow, cursorColumn)
        normalizeWideCharacterBoundary(cursorRow, cursorColumn + width)

        cells[index(cursorRow, cursorColumn)] = Cell(text: text, style: currentStyle, continuation: false)
        if width == 2 && cursorColumn + 1 < columns {
            cells[index(cursorRow, cursorColumn + 1)] = Cell(text: "", style: currentStyle, continuation: true)
        }

        if cursorColumn + width >= columns {
            cursorColumn = columns - 1
            wrapPending = autoWrapMode
        } else {
            cursorColumn += width
        }
    }

    private func appendCombiningCharacter(_ text: String) {
        var column = wrapPending ? cursorColumn : cursorColumn - 1
        while column >= 0 && cells[index(cursorRow, column)].continuation { column -= 1 }
        guard column >= 0, !cells[index(cursorRow, column)].text.isEmpty else { return }
        cells[index(cursorRow, column)].text += text
    }

    private func setGraphicsRendition(_ parameterText: String) {
        let parameters = Self.parseGraphicsParameters(parameterText)
        var index = 0

        while index < parameters.count {
            let code = parameters[index] ?? 0

            switch code {
            case 0: currentStyle = TerminalStyle()
            case 1: currentStyle.bold = true
            case 2: currentStyle.dim = true
            case 3: currentStyle.italic = true
            case 4, 21: currentStyle.underline = true
            case 7: currentStyle.inverse = true
            case 8: currentStyle.hidden = true
            case 9: currentStyle.strikethrough = true
            case 22:
                currentStyle.bold = false
                currentStyle.dim = false
            case 23: currentStyle.italic = false
            case 24: currentStyle.underline = false
            case 27: currentStyle.inverse = false
            case 28: currentStyle.hidden = false
            case 29: currentStyle.strikethrough = false
            case 39:
                currentStyle.foreground = nil
                currentStyle.foregroundPaletteIndex = nil
            case 49:
                currentStyle.background = nil
                currentStyle.backgroundPaletteIndex = nil
            case 30...37: setForeground(code - 30)
            case 40...47: setBackground(code - 40)
            case 90...97: setForeground(code - 90 + 8)
            case 100...107: setBackground(code - 100 + 8)
            case 38:
                if let (color, palette) = Self.readExtendedColor(parameters, &index) {
                    currentStyle.foreground = color
                    currentStyle.foregroundPaletteIndex = palette
                }
            case 48:
                if let (color, palette) = Self.readExtendedColor(parameters, &index) {
                    currentStyle.background = color
                    currentStyle.backgroundPaletteIndex = palette
                }
            default:
                break
            }

            index += 1
        }
    }

    private func setForeground(_ palette: Int) {
        currentStyle.foreground = Self.ansiColors[palette]
        currentStyle.foregroundPaletteIndex = palette
    }

    private func setBackground(_ palette: Int) {
        currentStyle.background = Self.ansiColors[palette]
        currentStyle.backgroundPaletteIndex = palette
    }

    private static func parseGraphicsParameters(_ text: String) -> [Int?] {
        guard !text.isEmpty else { return [0] }
        return text.drop { "?>!=".contains($0) }
            .split(separator: ";", omittingEmptySubsequences: false)
            .flatMap { $0.split(separator: ":", omittingEmptySubsequences: false) }
            .map { Int($0) }
    }

    private static func readExtendedColor(_ parameters: [Int?], _ index: inout Int) -> (TerminalColor, Int?)? {
        if index + 2 < parameters.count && parameters[index + 1] == 5 {
            let palette = clamp(parameters[index + 2] ?? 0, 0, 255)
            index += 2
            return (color256(palette), palette)
        }

        if index + 4 < parameters.count && parameters[index + 1] == 2 {
            var componentStart = index + 2
            // ISO-8613-6's colon form can include an omitted color-space id:
            // 38:2::R:G:B. The semicolon form starts directly at R.
            if parameters[componentStart] == nil { componentStart += 1 }
            guard componentStart + 2 < parameters.count else { return nil }

            func component(_ offset: Int) -> UInt8 {
                UInt8(clamp(parameters[componentStart + offset] ?? 0, 0, 255))
            }
            index = componentStart + 2
            return (TerminalColor(component(0), component(1), component(2)), nil)
        }

        return nil
    }

    public static func color256(_ index: Int) -> TerminalColor {
        let index = clamp(index, 0, 255)
        if index < 16 { return ansiColors[index] }
        if index >= 232 {
            let gray = UInt8(8 + (index - 232) * 10)
            return TerminalColor(gray, gray, gray)
        }
        let cube = index - 16
        func value(_ step: Int) -> UInt8 { step == 0 ? 0 : UInt8(55 + step * 40) }
        return TerminalColor(value(cube / 36), value((cube / 6) % 6), value(cube % 6))
    }

    // MARK: - Modes

    private func setPrivateModes(_ parameters: [Int], enabled: Bool) {
        for mode in parameters {
            switch mode {
            case 1: applicationCursorKeys = enabled
            case 6:
                originMode = enabled
                cursorRow = enabled ? scrollTop : 0
                cursorColumn = 0
            case 7:
                autoWrapMode = enabled
                wrapPending = false
            case 25: cursorVisible = enabled
            case 47, 1047, 1049: setAlternateScreen(enabled)
            case 1048: enabled ? saveCursor() : restoreCursor()
            case 1000, 1002, 1003:
                if enabled {
                    mouseTrackingMode = mode
                } else if mouseTrackingMode == mode {
                    mouseTrackingMode = 0
                }
            case 1004: focusReporting = enabled
            case 1006: sgrMouse = enabled
            case 2004: bracketedPaste = enabled
            case 2026: synchronizedOutput = enabled
            default: break
            }
        }
    }

    private func isPrivateModeEnabled(_ mode: Int) -> Bool {
        switch mode {
        case 1: return applicationCursorKeys
        case 6: return originMode
        case 7: return autoWrapMode
        case 25: return cursorVisible
        case 47, 1047, 1049: return alternateScreenActive
        case 1000, 1002, 1003: return mouseTrackingMode == mode
        case 1004: return focusReporting
        case 1006: return sgrMouse
        case 2004: return bracketedPaste
        case 2026: return synchronizedOutput
        default: return false
        }
    }

    private func setAlternateScreen(_ enabled: Bool) {
        if enabled && !alternateScreenActive {
            savedMainScreen = SavedScreen(
                cells: cells,
                wrappedFromPrevious: wrappedFromPrevious,
                cursorRow: cursorRow,
                cursorColumn: cursorColumn,
                savedRow: savedRow,
                savedColumn: savedColumn,
                scrollTop: scrollTop,
                scrollBottom: scrollBottom,
                style: currentStyle,
                originMode: originMode,
                autoWrapMode: autoWrapMode)
            alternateScreenActive = true
            currentStyle = TerminalStyle()
            originMode = false
            autoWrapMode = true
            cells = Array(repeating: Cell.blank, count: rows * columns)
            wrappedFromPrevious = Array(repeating: false, count: rows)
            cursorRow = 0
            cursorColumn = 0
            scrollTop = 0
            scrollBottom = rows - 1
            return
        }

        if !enabled && alternateScreenActive, let saved = savedMainScreen {
            cells = saved.cells
            wrappedFromPrevious = saved.wrappedFromPrevious
            cursorRow = saved.cursorRow
            cursorColumn = saved.cursorColumn
            savedRow = saved.savedRow
            savedColumn = saved.savedColumn
            scrollTop = saved.scrollTop
            scrollBottom = saved.scrollBottom
            currentStyle = saved.style
            originMode = saved.originMode
            autoWrapMode = saved.autoWrapMode
            savedMainScreen = nil
            alternateScreenActive = false
            wrapPending = false
        }
    }

    private func fullReset() {
        if alternateScreenActive { setAlternateScreen(false) }
        currentStyle = TerminalStyle()
        applicationCursorKeys = false
        autoWrapMode = true
        originMode = false
        bracketedPaste = false
        focusReporting = false
        mouseTrackingMode = 0
        sgrMouse = false
        synchronizedOutput = false
        cursorVisible = true
        scrollTop = 0
        scrollBottom = rows - 1
        clearAll()
        cursorRow = 0
        cursorColumn = 0
        wrapPending = false
    }

    private func setScrollRegion(_ parameters: [Int]) {
        let top = Self.parameter(parameters, 0, 1) - 1
        let bottom = Self.parameter(parameters, 1, rows) - 1
        guard top < bottom && top >= 0 && bottom < rows else { return }
        scrollTop = top
        scrollBottom = bottom
        cursorRow = originMode ? scrollTop : 0
        cursorColumn = 0
    }

    private func saveCursor() {
        savedColumn = cursorColumn
        savedRow = cursorRow
    }

    private func restoreCursor() {
        wrapPending = false
        cursorColumn = savedColumn
        cursorRow = savedRow
        clampCursor()
    }

    // MARK: - Scrolling and erasing

    private func lineFeed(wrapped: Bool) {
        if cursorRow == scrollBottom {
            scrollRegionUp(scrollTop, scrollBottom, 1)
            wrappedFromPrevious[cursorRow] = wrapped
            return
        }
        cursorRow = min(rows - 1, cursorRow + 1)
        wrappedFromPrevious[cursorRow] = wrapped
    }

    private func reverseIndex() {
        if cursorRow == scrollTop {
            scrollRegionDown(scrollTop, scrollBottom, 1)
            return
        }
        cursorRow = max(0, cursorRow - 1)
    }

    private func scrollRegionUp(_ top: Int, _ bottom: Int, _ count: Int, feedScrollback: Bool = true) {
        let count = clamp(count, 1, bottom - top + 1)

        if feedScrollback && !alternateScreenActive && top == 0 && bottom == rows - 1 {
            for row in 0..<count { addScrollbackRow(row) }
        }

        if top <= bottom - count {
            for row in top...(bottom - count) {
                copyRow(row + count, row)
                wrappedFromPrevious[row] = wrappedFromPrevious[row + count]
            }
        }
        for row in (bottom - count + 1)...bottom { clearRow(row) }
    }

    private func scrollRegionDown(_ top: Int, _ bottom: Int, _ count: Int) {
        let count = clamp(count, 1, bottom - top + 1)

        if top + count <= bottom {
            for row in stride(from: bottom, through: top + count, by: -1) {
                copyRow(row - count, row)
                wrappedFromPrevious[row] = wrappedFromPrevious[row - count]
            }
        }
        for row in top..<(top + count) { clearRow(row) }
    }

    private func insertLines(_ count: Int) {
        guard cursorRow >= scrollTop && cursorRow <= scrollBottom else { return }
        scrollRegionDown(cursorRow, scrollBottom, count)
    }

    private func deleteLines(_ count: Int) {
        guard cursorRow >= scrollTop && cursorRow <= scrollBottom else { return }
        // Deleted lines are discarded; they never feed the scrollback.
        scrollRegionUp(cursorRow, scrollBottom, count, feedScrollback: false)
    }

    private func eraseDisplay(_ mode: Int) {
        switch mode {
        case 2, 3:
            clearAll()
            if mode == 3 && !alternateScreenActive {
                scrollbackStartIndex += scrollback.count
                scrollback.removeAll()
            }
        case 1:
            for row in 0..<cursorRow { clearRow(row) }
            clearCells(cursorRow, 0, cursorColumn + 1)
        default:
            clearCells(cursorRow, cursorColumn, columns - cursorColumn)
            for row in (cursorRow + 1)..<max(cursorRow + 1, rows) { clearRow(row) }
        }
    }

    private func eraseLine(_ mode: Int) {
        switch mode {
        case 2: clearRow(cursorRow)
        case 1: clearCells(cursorRow, 0, cursorColumn + 1)
        default: clearCells(cursorRow, cursorColumn, columns - cursorColumn)
        }
    }

    private func deleteCharacters(_ count: Int) {
        let count = clamp(count, 1, columns - cursorColumn)
        normalizeWideCharacterBoundary(cursorRow, cursorColumn)
        normalizeWideCharacterBoundary(cursorRow, cursorColumn + count)

        for column in cursorColumn..<max(cursorColumn, columns - count) {
            cells[index(cursorRow, column)] = cells[index(cursorRow, column + count)]
        }
        clearCells(cursorRow, columns - count, count)
        normalizeRow(cursorRow)
    }

    private func insertCharacters(_ count: Int) {
        let count = clamp(count, 1, columns - cursorColumn)
        normalizeWideCharacterBoundary(cursorRow, cursorColumn)

        if cursorColumn + count <= columns - 1 {
            for column in stride(from: columns - 1, through: cursorColumn + count, by: -1) {
                cells[index(cursorRow, column)] = cells[index(cursorRow, column - count)]
            }
        }
        clearCells(cursorRow, cursorColumn, count)
        normalizeRow(cursorRow)
    }

    private func eraseCharacters(_ count: Int) {
        clearCells(cursorRow, cursorColumn, clamp(count, 1, columns - cursorColumn))
    }

    private func clearAll() {
        for row in 0..<rows { clearRow(row) }
    }

    private func clearRow(_ row: Int) {
        clearCells(row, 0, columns)
        wrappedFromPrevious[row] = false
    }

    private func clearCells(_ row: Int, _ start: Int, _ count: Int) {
        var start = start
        var end = min(columns, start + count)
        if start > 0 && start < columns && cells[index(row, start)].continuation { start -= 1 }
        if end < columns && cells[index(row, end)].continuation { end += 1 }

        let empty = Cell(text: " ", style: currentStyle, continuation: false)
        for column in max(0, start)..<max(max(0, start), end) {
            cells[index(row, column)] = empty
        }
    }

    private func normalizeWideCharacterBoundary(_ row: Int, _ column: Int) {
        guard column > 0 && column < columns, cells[index(row, column)].continuation else { return }
        let empty = Cell(text: " ", style: currentStyle, continuation: false)
        cells[index(row, column - 1)] = empty
        cells[index(row, column)] = empty
    }

    private func normalizeRow(_ row: Int) {
        for column in 0..<columns where cells[index(row, column)].continuation {
            if column == 0 || cells[index(row, column - 1)].text.allSatisfy(\.isWhitespace) {
                cells[index(row, column)] = Cell(text: " ", style: currentStyle, continuation: false)
            }
        }
    }

    private func copyRow(_ source: Int, _ destination: Int) {
        let from = source * columns
        let to = destination * columns
        for column in 0..<columns { cells[to + column] = cells[from + column] }
    }

    private func clampCursor() {
        cursorColumn = clamp(cursorColumn, 0, columns - 1)
        cursorRow = originMode
            ? clamp(cursorRow, scrollTop, scrollBottom)
            : clamp(cursorRow, 0, rows - 1)
    }

    @inline(__always)
    private func index(_ row: Int, _ column: Int) -> Int { row * columns + column }

    private static func resizeCells(_ source: [Cell], columns: Int, rows: Int, newColumns: Int, newRows: Int) -> [Cell] {
        var resized = Array(repeating: Cell.blank, count: newRows * newColumns)
        for row in 0..<min(rows, newRows) {
            for column in 0..<min(columns, newColumns) {
                resized[row * newColumns + column] = source[row * columns + column]
            }
        }
        // A wide glyph cut at the new right edge leaves an orphan; clear it.
        if newColumns < columns {
            for row in 0..<min(rows, newRows) {
                let last = row * newColumns + newColumns - 1
                if CellWidth.of(resized[last].text.unicodeScalars.first ?? " ") == 2 {
                    resized[last] = .blank
                }
            }
        }
        return resized
    }

    private static func resizeWrapState(_ source: [Bool], _ rows: Int) -> [Bool] {
        var resized = Array(repeating: false, count: rows)
        for row in 0..<min(rows, source.count) { resized[row] = source[row] }
        return resized
    }

    // MARK: - Snapshots

    private func createSnapshot() -> TerminalSnapshot {
        if snapshotCells.count != cells.count || snapshotLines.count != rows {
            snapshotCells = Array(repeating: Cell.blank, count: cells.count)
            snapshotLines = Array(repeating: nil, count: rows)
        }

        var lastVisibleRow = alternateScreenActive ? rows - 1 : cursorRow
        if !alternateScreenActive {
            for row in stride(from: rows - 1, through: 0, by: -1) where lastCharacter(row) >= 0 {
                lastVisibleRow = max(lastVisibleRow, row)
                break
            }
        }

        var screen: [TerminalLine] = []
        screen.reserveCapacity(lastVisibleRow + 1)

        for row in 0...lastVisibleRow {
            var cellLength = lastCharacter(row) + 1
            if row == cursorRow { cellLength = max(cellLength, cursorColumn + 1) }

            let base = row * columns
            var unchanged = snapshotLines[row]?.cellLength == cellLength
            var column = 0
            while unchanged && column < cellLength {
                unchanged = snapshotCells[base + column] == cells[base + column]
                column += 1
            }

            if !unchanged {
                snapshotLines[row] = Self.createLine(cells[base..<(base + columns)], cellLength: cellLength)
                for column in 0..<cellLength { snapshotCells[base + column] = cells[base + column] }
            }
            screen.append(snapshotLines[row]!)
        }

        return TerminalSnapshot(
            scrollback: alternateScreenActive ? [] : scrollback,
            screen: screen,
            cursorRow: cursorRow,
            cursorColumn: cursorColumn,
            cursorVisible: cursorVisible,
            scrollbackStartIndex: scrollbackStartIndex,
            modes: currentModes,
            title: title,
            revision: revision)
    }

    public var modes: TerminalModes {
        lock.lock(); defer { lock.unlock() }
        return currentModes
    }

    private var currentModes: TerminalModes {
        var modes = TerminalModes()
        modes.alternateScreen = alternateScreenActive
        modes.applicationCursorKeys = applicationCursorKeys
        modes.bracketedPaste = bracketedPaste
        modes.focusReporting = focusReporting
        modes.mouseTrackingMode = mouseTrackingMode
        modes.sgrMouse = sgrMouse
        modes.synchronizedOutput = synchronizedOutput
        return modes
    }

    private static func createLine(_ row: ArraySlice<Cell>, cellLength: Int) -> TerminalLine {
        var runs: [TerminalRun] = []
        var text = ""
        var style: TerminalStyle?

        for cell in row.prefix(cellLength) where !cell.continuation {
            if let current = style, current != cell.style {
                runs.append(TerminalRun(text: text, style: current))
                text = ""
            }
            style = cell.style
            text += cell.text
        }

        if !text.isEmpty { runs.append(TerminalRun(text: text, style: style ?? TerminalStyle())) }
        return TerminalLine(runs: runs, cellLength: cellLength)
    }

    private func lastCharacter(_ row: Int) -> Int {
        let base = row * columns
        for column in stride(from: columns - 1, through: 0, by: -1) {
            let cell = cells[base + column]
            if cell.continuation || cell.text != " " || cell.style.hasVisibleStyle { return column }
        }
        return -1
    }

    private func addScrollbackRow(_ row: Int) {
        let base = row * columns
        let slice = cells[base..<(base + columns)]
        var length = columns
        while length > 0 {
            let cell = slice[base + length - 1]
            if cell.continuation || cell.text != " " || cell.style.hasVisibleStyle { break }
            length -= 1
        }
        scrollback.append(Self.createLine(slice, cellLength: length))
        if scrollback.count > maximumScrollbackRows + 128 { trimScrollback() }
    }

    private func trimScrollback() {
        guard scrollback.count > maximumScrollbackRows else { return }
        let removeCount = scrollback.count - maximumScrollbackRows
        scrollback.removeFirst(removeCount)
        scrollbackStartIndex += removeCount
    }

    private static func normalizeHistorySize(_ size: Int) -> Int {
        supportedHistorySizes.contains(size) ? size : defaultHistorySize
    }

    private struct Cell: Equatable {
        var text: String
        var style: TerminalStyle
        var continuation: Bool

        static let blank = Cell(text: " ", style: TerminalStyle(), continuation: false)
    }

    private struct SavedScreen {
        var cells: [Cell]
        var wrappedFromPrevious: [Bool]
        var cursorRow: Int
        var cursorColumn: Int
        var savedRow: Int
        var savedColumn: Int
        var scrollTop: Int
        var scrollBottom: Int
        var style: TerminalStyle
        var originMode: Bool
        var autoWrapMode: Bool
    }

    private enum ParserState {
        case normal, escape, csi, osc, oscEscape, dcs, dcsEscape
        case controlString, controlStringEscape, ignoreNext
    }
}

@inline(__always)
func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
    min(max(value, lower), upper)
}
