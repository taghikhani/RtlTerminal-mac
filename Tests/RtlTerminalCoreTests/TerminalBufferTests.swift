import Testing
@testable import RtlTerminalCore

struct TerminalBufferTests {
    private func text(_ snapshot: TerminalSnapshot) -> String {
        (0..<snapshot.lineCount).map { snapshot.line($0).text }.joined(separator: "\n")
    }

    private func trimmed(_ value: String) -> String {
        var value = value
        while let last = value.last, last.isWhitespace { value.removeLast() }
        return value
    }

    @Test func alternateScreenIsIsolated() {
        let buffer = TerminalBuffer(columns: 20, rows: 6)
        buffer.process("shell history\r\nsecond line")
        buffer.process("\u{1b}[?1049hOpenCode")
        let alternate = buffer.snapshot()
        #expect(alternate.modes.alternateScreen)
        #expect(alternate.scrollbackCount == 0)
        #expect(alternate.lineCount == 6)
        #expect(text(alternate).contains("OpenCode"))
        #expect(!(text(alternate).contains("shell history")))

        buffer.process("\u{1b}[?1049l")
        let restored = buffer.snapshot()
        #expect(!restored.modes.alternateScreen)
        #expect(text(restored).contains("shell history"))
    }

    @Test func styledTrailingSpacesRemainVisible() {
        let buffer = TerminalBuffer(columns: 20, rows: 5)
        buffer.process("\u{1b}[48;2;33;35;55m    \u{1b}[0m")
        let line = buffer.snapshot().line(0)
        #expect(line.cellLength >= 4)
        #expect(line.runs.contains { $0.style.background == TerminalColor(33, 35, 55) })
    }

    @Test func sgrAttributesResetIndependently() {
        let buffer = TerminalBuffer(columns: 20, rows: 5)
        buffer.process("\u{1b}[4;7;9mA\u{1b}[24;27;29mB")
        let runs = buffer.snapshot().line(0).runs
        let first = runs.first { $0.text.contains("A") }!.style
        let second = runs.first { $0.text.contains("B") }!.style
        #expect(first.underline && first.inverse && first.strikethrough)
        #expect(!(second.underline || second.inverse || second.strikethrough))
    }

    @Test func colonTrueColorIsParsed() {
        let buffer = TerminalBuffer(columns: 20, rows: 5)
        buffer.process("\u{1b}[38:2::91:145:255mX")
        #expect(buffer.snapshot().line(0).runs[0].style.foreground == TerminalColor(91, 145, 255))
    }

    @Test func colorOriginsArePreserved() {
        let buffer = TerminalBuffer(columns: 30, rows: 5)
        buffer.process(
            "\u{1b}[31;41mA\u{1b}[38;2;197;15;31;48;2;197;15;31mB\u{1b}[0m" +
            "\u{1b}[38;5;1;48;5;1mC\u{1b}[90;100mD\u{1b}[38;5;231;48;5;231mE" +
            "\u{1b}[39mF\u{1b}[49mG\u{1b}[0mI\u{1b}[38;5;243;48;5;243mJ")
        let line = buffer.snapshot().line(0)
        func style(_ character: Character) -> TerminalStyle {
            line.runs.first { $0.text.contains(character) }!.style
        }

        #expect(style("A").foreground == style("B").foreground)
        #expect(style("A").foregroundPaletteIndex == 1)
        #expect(style("B").foregroundPaletteIndex == nil)
        #expect(style("C").backgroundPaletteIndex == 1)
        #expect(style("D").foregroundPaletteIndex == 8)
        #expect(style("E").foregroundPaletteIndex == 231)
        #expect(style("F").foreground == nil)
        #expect(style("F").foregroundPaletteIndex == nil)
        #expect(style("G").background == nil)
        #expect(style("I") == TerminalStyle())
        #expect(style("J").foreground == TerminalColor(118, 118, 118))
    }

    @Test func capabilityQueriesReceiveReplies() {
        let buffer = TerminalBuffer(columns: 20, rows: 5)
        let responses = buffer.process("\u{1b}[6n\u{1b}[c\u{1b}]11;?\u{07}")
        #expect(responses.contains { $0.hasSuffix("R") })
        #expect(responses.contains { $0.hasSuffix("c") })
        #expect(responses.contains { $0.hasPrefix("\u{1b}]11;rgb:") })
    }

    @Test func openTuiHandshakeDoesNotLeak() {
        let buffer = TerminalBuffer(columns: 30, rows: 6)
        let responses = buffer.process(
            "\u{1b}]10;?\u{1b}\\" +
            "\u{1b}]11;?\u{1b}\\" +
            "\u{1b}[>0q" +
            "\u{1b}P+q4d73\u{1b}\\" +
            "\u{1b}[?1016$p\u{1b}[?2027$p\u{1b}[?2031$p" +
            "\u{1b}[?1004$p\u{1b}[?2004$p\u{1b}[?2026$p" +
            "\u{1b}[?u" +
            "\u{1b}]99;i=opentui-notifications:p=?;\u{1b}\\" +
            "\u{1b}]1337;Capabilities\u{1b}\\" +
            "\u{1b}_Gi=31337,s=1,v=1,a=q,t=d,f=24;AAAA\u{1b}\\" +
            "\u{1b}[>4;1mX")
        let snapshot = buffer.snapshot()
        let visible = text(snapshot)
        #expect(!(visible.contains("4d73")))
        #expect(!(visible.contains("Gi=31337")))
        #expect(!(visible.contains("Capabilities")))
        let xStyle = snapshot.line(0).runs.first { $0.text.contains("X") }!.style
        #expect(!(xStyle.bold || xStyle.underline))
        #expect(responses.contains { $0.contains("RtlTerminal") })
        #expect(responses.contains { $0.contains("0+r4d73") })
        #expect(responses.filter { $0.hasSuffix("$y") }.count == 6)
    }

    @Test func modernTuiModesAreTracked() {
        let buffer = TerminalBuffer(columns: 20, rows: 5)
        buffer.process("\u{1b}[?1h\u{1b}[?2004h\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?2026h")
        var modes = buffer.modes
        #expect(modes.applicationCursorKeys)
        #expect(modes.bracketedPaste)
        #expect(modes.mouseTrackingMode == 1002)
        #expect(modes.sgrMouse)
        #expect(modes.synchronizedOutput)

        buffer.process("\u{1b}[?1l\u{1b}[?2004l\u{1b}[?1002l\u{1b}[?1006l\u{1b}[?2026l")
        modes = buffer.modes
        #expect(modes == TerminalModes())
    }

    @Test func staleMouseReportingIsReset() {
        let buffer = TerminalBuffer(columns: 20, rows: 5)
        buffer.process("\u{1b}[?2004h\u{1b}[?1003h\u{1b}[?1006h\u{1b}[?1004h")
        #expect(buffer.resetMouseReporting())
        let modes = buffer.modes
        #expect(modes.mouseTrackingMode == 0)
        #expect(!modes.sgrMouse)
        #expect(!modes.focusReporting)
        #expect(modes.bracketedPaste)
        #expect(!buffer.resetMouseReporting())
    }

    @Test func emojiClustersKeepWidth() {
        let buffer = TerminalBuffer(columns: 20, rows: 5)
        buffer.process("👨‍💻🇮🇷X")
        let line = buffer.snapshot().line(0)
        #expect(line.cellLength == 6)
        #expect(line.text == "👨‍💻🇮🇷X ")
    }

    @Test func persianZeroWidthNonJoinerStaysInCell() {
        let buffer = TerminalBuffer(columns: 20, rows: 5)
        buffer.process("می‌خواهم")
        let snapshot = buffer.snapshot()
        #expect(trimmed(snapshot.line(0).text) == "می‌خواهم")
        // ZWNJ has no width: 7 letters, cursor after them.
        #expect(snapshot.cursorColumn == 7)
    }

    @Test func splitUtf8SequencesAreDecoded() {
        let buffer = TerminalBuffer(columns: 20, rows: 5)
        let bytes = Array("سلام".utf8)
        for byte in bytes {
            [byte].withUnsafeBufferPointer { _ = buffer.process(bytes: $0) }
        }
        #expect(trimmed(buffer.snapshot().line(0).text) == "سلام")
    }

    @Test func carriageReturnIsImmediate() {
        let buffer = TerminalBuffer(columns: 20, rows: 5)
        buffer.process("Working\r")
        #expect(buffer.snapshot().cursorColumn == 0)
        buffer.process("\u{1b}[KDone")
        #expect(trimmed(text(buffer.snapshot())) == "Done")
    }

    @Test func stylePreservesWrap() {
        let buffer = TerminalBuffer(columns: 10, rows: 5)
        buffer.process("1234567890\u{1b}[31mW")
        let snapshot = buffer.snapshot()
        #expect(snapshot.line(0).text == "1234567890")
        #expect(snapshot.cursorRow == 1)
        #expect(snapshot.cursorColumn == 1)
    }

    @Test func statusRedrawAtEveryReadBoundary() {
        let stream = Array(("Working (0s - esc to interrupt)\r\nold footer" +
            "\u{1b}[1A\r\u{1b}[2KWorking 3\u{1b}[1B\r\u{1b}[2Knew footer").utf8)
        let expectedBuffer = TerminalBuffer(columns: 40, rows: 6)
        stream.withUnsafeBufferPointer { _ = expectedBuffer.process(bytes: $0) }
        let expected = text(expectedBuffer.snapshot())

        for split in 0...stream.count {
            let buffer = TerminalBuffer(columns: 40, rows: 6)
            Array(stream[..<split]).withUnsafeBufferPointer { _ = buffer.process(bytes: $0) }
            Array(stream[split...]).withUnsafeBufferPointer { _ = buffer.process(bytes: $0) }
            #expect(text(buffer.snapshot()) == expected, "read boundary \(split)")
        }
        #expect(trimmed(expected) == "Working 3\nnew footer")

        let shortUpdate = TerminalBuffer(columns: 30, rows: 6)
        shortUpdate.process("WWorking\r\u{1b}[P")
        #expect(trimmed(text(shortUpdate.snapshot())) == "Working")
    }

    @Test func wideErase() {
        let buffer = TerminalBuffer(columns: 30, rows: 6)
        buffer.process("👨‍💻Working\r\u{1b}[2X")
        #expect(trimmed(text(buffer.snapshot())) == "  Working")
        buffer.process("\rOK\u{1b}[K")
        #expect(trimmed(text(buffer.snapshot())) == "OK")
    }

    @Test func snapshotReuse() {
        let buffer = TerminalBuffer(columns: 40, rows: 8)
        buffer.process("\u{1b}[?1049hسلام English\r\nunchanged\u{1b}[1;1H")
        let first = buffer.snapshot()
        buffer.process("\u{1b}[0m")
        let second = buffer.snapshot()
        for row in 0..<first.lineCount { #expect(first.line(row) === second.line(row)) }

        buffer.process("\u{1b}[1;1H\u{1b}[31mX")
        let edited = buffer.snapshot()
        #expect(!(second.line(0) === edited.line(0)))
        #expect(second.line(1) === edited.line(1))

        buffer.process("\u{1b}[1;1H\u{1b}[2K")
        #expect(!(text(buffer.snapshot()).contains("سلام")))

        buffer.resize(columns: 60, rows: 10)
        buffer.process("\u{1b}[1;1Hnew")
        #expect(text(buffer.snapshot()).hasPrefix("new"))

        buffer.process("\u{1b}[?1049l")
        #expect(!(text(buffer.snapshot()).contains("unchanged")))
    }

    @Test func scrollbackAndHistoryLimit() {
        let buffer = TerminalBuffer(columns: 20, rows: 5, maximumScrollbackRows: 2000)
        for line in 0..<2500 { buffer.process("line \(line)\r\n") }
        let snapshot = buffer.snapshot()
        #expect(snapshot.scrollbackCount <= 2000 + 128)
        #expect(trimmed(snapshot.screen[3].text) == "line 2499")

        buffer.clearScrollback()
        #expect(buffer.snapshot().scrollbackCount == 0)
    }

    @Test func deleteLinesDoesNotFeedScrollback() {
        let buffer = TerminalBuffer(columns: 20, rows: 5)
        buffer.process("a\r\nb\r\nc\u{1b}[1;1H\u{1b}[M")
        let snapshot = buffer.snapshot()
        #expect(snapshot.scrollbackCount == 0)
        #expect(trimmed(snapshot.line(0).text) == "b")
    }

    @Test func windowTitle() {
        let buffer = TerminalBuffer(columns: 20, rows: 5)
        buffer.process("\u{1b}]0;ترمینال\u{07}")
        #expect(buffer.snapshot().title == "ترمینال")
    }

    @Test func resizeAcrossEqualCellCounts() {
        let buffer = TerminalBuffer(columns: 30, rows: 10)
        buffer.process("hello")
        _ = buffer.snapshot()
        buffer.resize(columns: 15, rows: 20)
        buffer.process("\u{1b}[20;1Hbottom")
        let snapshot = buffer.snapshot()
        #expect(trimmed(snapshot.line(snapshot.lineCount - 1).text) == "bottom")
    }
}
