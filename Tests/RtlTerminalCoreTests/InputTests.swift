import Testing
@testable import RtlTerminalCore

struct InputTests {
    @Test func cursorKeys() {
        #expect(KeyEncoder.sequence(for: .up, modifiers: [], applicationCursorKeys: false) == "\u{1b}[A")
        #expect(KeyEncoder.sequence(for: .up, modifiers: [], applicationCursorKeys: true) == "\u{1b}OA")
        #expect(KeyEncoder.sequence(for: .left, modifiers: [.alt], applicationCursorKeys: false) == "\u{1b}[1;3D")
        #expect(KeyEncoder.sequence(for: .right, modifiers: [.control, .shift], applicationCursorKeys: true) == "\u{1b}[1;6C")
    }

    @Test func editingAndFunctionKeys() {
        #expect(KeyEncoder.sequence(for: .tab, modifiers: [.shift], applicationCursorKeys: false) == "\u{1b}[Z")
        #expect(KeyEncoder.sequence(for: .delete, modifiers: [], applicationCursorKeys: false) == "\u{1b}[3~")
        #expect(KeyEncoder.sequence(for: .pageUp, modifiers: [.shift], applicationCursorKeys: false) == "\u{1b}[5;2~")
        #expect(KeyEncoder.sequence(for: .function(1), modifiers: [], applicationCursorKeys: false) == "\u{1b}OP")
        #expect(KeyEncoder.sequence(for: .function(5), modifiers: [], applicationCursorKeys: false) == "\u{1b}[15~")
        #expect(KeyEncoder.sequence(for: .function(12), modifiers: [.control], applicationCursorKeys: false) == "\u{1b}[24;5~")
        #expect(KeyEncoder.sequence(for: .backspace, modifiers: [], applicationCursorKeys: false) == "\u{7f}")
        #expect(KeyEncoder.sequence(for: .enter, modifiers: [.alt], applicationCursorKeys: false) == "\u{1b}\r")
    }

    @Test func controlCharacters() {
        #expect(KeyEncoder.controlCharacter(for: "c") == "\u{03}")
        #expect(KeyEncoder.controlCharacter(for: "C") == "\u{03}")
        #expect(KeyEncoder.controlCharacter(for: "[") == "\u{1b}")
        #expect(KeyEncoder.controlCharacter(for: " ") == "\u{0}")
        #expect(KeyEncoder.controlCharacter(for: "س") == nil)
    }

    @Test func pasteAndPaths() {
        #expect(KeyEncoder.paste("a\nb", bracketed: false) == "a\rb")
        #expect(KeyEncoder.paste("x\u{1b}[201~y", bracketed: true) == "\u{1b}[200~xy\u{1b}[201~")
        #expect(KeyEncoder.shellEscaped("/Users/me/file.txt") == "/Users/me/file.txt")
        #expect(KeyEncoder.shellEscaped("/Users/me/پوشه من/it's") == "'/Users/me/پوشه من/it'\\''s'")
    }

    @Test func sgrMouse() {
        #expect(KeyEncoder.sgrMouse(button: 0, x: 3, y: 4, released: false, modifiers: []) == "\u{1b}[<0;3;4M")
        #expect(KeyEncoder.sgrMouse(button: 64, x: 1, y: 1, released: true, modifiers: [.control]) == "\u{1b}[<80;1;1m")
    }

    @Test func linkDetection() {
        let links = LinkDetector.links(in: "see https://example.com/a?b=1). and www.test.org")
        #expect(links.count == 2)
        #expect(links[0].url.absoluteString == "https://example.com/a?b=1")
        #expect(links[1].url.absoluteString == "https://www.test.org")
        #expect(links[0].contains(4))
    }

    @Test func lightThemeMapsOnlyAnsiColors() {
        var style = TerminalStyle()
        style.foreground = TerminalBuffer.ansiColors[1]
        style.foregroundPaletteIndex = 1
        #expect(TerminalTheme.light.colors(for: style).foreground == TerminalColor(207, 34, 46))
        style.foregroundPaletteIndex = nil
        #expect(TerminalTheme.light.colors(for: style).foreground == TerminalBuffer.ansiColors[1])
        style.inverse = true
        #expect(TerminalTheme.dark.colors(for: style).background == TerminalBuffer.ansiColors[1])
    }
}
