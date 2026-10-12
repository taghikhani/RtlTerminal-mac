import Testing
@testable import RtlTerminalCore

struct SmartRtlTests {
    private func line(_ text: String) -> TerminalLine {
        TerminalLine(runs: [TerminalRun(text: text, style: TerminalStyle())], cellLength: text.count)
    }

    private func pieces(_ text: String, rtl: Bool) -> [(String, Bool)] {
        let units = Array(text.utf16)
        return SmartRtl.directionalSpans(text, baseRightToLeft: rtl).map {
            (String(decoding: units[$0.start..<($0.start + $0.length)], as: UTF16.self), $0.isRightToLeft)
        }
    }

    @Test func persianIsDetectedAndRightAligned() {
        let persian = line("status: سلام دنیا 123")
        #expect(persian.containsRightToLeft)
        #expect(SmartRtl.shouldRightAlign(persian, smartRtlEnabled: true, preserveTerminalGrid: false))
        #expect(!(SmartRtl.shouldRightAlign(persian, smartRtlEnabled: true, preserveTerminalGrid: true)))
        #expect(!(SmartRtl.shouldRightAlign(persian, smartRtlEnabled: false, preserveTerminalGrid: false)))
        #expect(!(line("plain English").containsRightToLeft))
    }

    @Test func englishFragmentsKeepTheirOrder() {
        let result = pieces("فایل config.json پیدا نشد", rtl: true)
        #expect(result.map(\.0) == ["فایل ", "config.json", " پیدا نشد"])
        #expect(result.map(\.1) == [true, false, true])
    }

    @Test func numbersAndPathsStayLeftToRight() {
        let result = pieces("نسخه 1.2.3 در /usr/local/bin", rtl: true)
        #expect(result.contains { $0.0 == "1.2.3" && !$0.1 })
        #expect(result.contains { $0.0 == "/usr/local/bin" && !$0.1 })
        #expect(pieces("اجرای --version", rtl: true).contains { $0.0 == "--version" && !$0.1 })
    }

    @Test func bracketsFollowTheirContent() {
        let result = pieces("Run (سلام) now", rtl: false)
        #expect(result.contains { $0.0.contains("(سلام)") && $0.1 })
    }

    @Test func arabicWithLeftToRightBase() {
        let result = pieces("Error: الملف غير موجود", rtl: false)
        #expect(result.first?.1 == false)
        #expect(result.last?.0 == "الملف غير موجود")
        #expect(result.last?.1 == true)
    }

    @Test func rowLayoutPlacesRtlTextOnTheRight() {
        let layout = RowLayout(
            line: line("سلام world"), smartRtl: true, rowRtl: false,
            preserveTerminalGrid: false, cellWidth: 10, viewportWidth: 200)
        // 10 cells right-aligned in a 20-cell viewport.
        #expect(layout.cells.map(\.x).min() == 100)
        // "world" keeps its internal order and sits left of the Persian word.
        let world = layout.cells.filter { !$0.isRightToLeft && $0.width > 0 && $0.start >= 5 }
        #expect(world.map(\.x) == [100, 110, 120, 130, 140])
        let seen = layout.cells.first { $0.start == 0 }!
        #expect(seen.x == 190)
        #expect(layout.glyphs.contains { $0.text == "سلام" && $0.isRightToLeft && $0.width == 40 })
    }

    @Test func rowLayoutPreservesGridInFullScreenApps() {
        let layout = RowLayout(
            line: line("│ سلام │"), smartRtl: true, rowRtl: false,
            preserveTerminalGrid: true, cellWidth: 10, viewportWidth: 200)
        // Not right-aligned: the row keeps its grid origin at x = 0.
        #expect(layout.cells.map(\.x).min() == 0)
        #expect(layout.cells.map { $0.x + $0.width }.max() == 80)
    }

    @Test func logicalColumnInsideRtlWord() {
        let layout = RowLayout(
            line: line("ab سلام"), smartRtl: false, rowRtl: false,
            preserveTerminalGrid: false, cellWidth: 10, viewportWidth: 200)
        // "سلام" occupies columns 3–6 drawn right to left from x=30..70.
        #expect(layout.logicalColumn(atX: 65, cellWidth: 10) == 3)
        #expect(layout.logicalColumn(atX: 35, cellWidth: 10) == 6)
        #expect(layout.cell(atColumn: 3)?.start == 3)
    }
}
