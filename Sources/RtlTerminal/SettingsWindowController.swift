#if canImport(AppKit)
import AppKit
import RtlTerminalCore

/// Font, history, theme and shell preferences. Changes apply immediately.
final class SettingsWindowController: NSWindowController {
    private let fontPopup = NSPopUpButton()
    private let sizeField = NSTextField()
    private let sizeStepper = NSStepper()
    private let boldCheckbox = NSButton(checkboxWithTitle: "Bold", target: nil, action: nil)
    private let italicCheckbox = NSButton(checkboxWithTitle: "Italic", target: nil, action: nil)
    private let rtlFontPopup = NSPopUpButton()
    private let historyPopup = NSPopUpButton()
    private let themePopup = NSPopUpButton()
    private let shellPopup = NSPopUpButton()
    private let smartRtlCheckbox = NSButton(checkboxWithTitle: "Smart RTL (right-align Persian/Arabic lines)", target: nil, action: nil)
    private let rowRtlCheckbox = NSButton(checkboxWithTitle: "Row RTL (force right-to-left rows, also in full-screen apps)", target: nil, action: nil)
    private let optionAsMetaCheckbox = NSButton(checkboxWithTitle: "Use Option as Meta key", target: nil, action: nil)
    private let preview = NSTextField(labelWithString: "سلام دنیا — Hello, world 123")

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildInterface()
        load()
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func buildInterface() {
        let fonts = NSFontManager.shared.availableFontFamilies
        let installed = Set(fonts)

        fontPopup.addItem(withTitle: "System Monospaced")
        fontPopup.lastItem?.representedObject = ""
        addFontItems(to: fontPopup, recommended: Settings.recommendedFonts.filter(installed.contains),
                     all: fonts.filter(isFixedPitch))

        rtlFontPopup.addItem(withTitle: "Automatic (system fallback)")
        rtlFontPopup.lastItem?.representedObject = ""
        addFontItems(to: rtlFontPopup, recommended: Settings.recommendedRtlFonts.filter(installed.contains), all: fonts)

        sizeStepper.minValue = Settings.minimumFontSize
        sizeStepper.maxValue = Settings.maximumFontSize
        sizeStepper.increment = 1
        sizeStepper.valueWraps = false
        sizeField.formatter = {
            let formatter = NumberFormatter()
            formatter.minimum = NSNumber(value: Settings.minimumFontSize)
            formatter.maximum = NSNumber(value: Settings.maximumFontSize)
            formatter.maximumFractionDigits = 1
            return formatter
        }()
        sizeField.widthAnchor.constraint(equalToConstant: 50).isActive = true

        for size in TerminalBuffer.supportedHistorySizes {
            historyPopup.addItem(withTitle: "\(size.formatted()) lines")
            historyPopup.lastItem?.representedObject = size
        }

        for theme in ThemePreference.allCases {
            themePopup.addItem(withTitle: theme.title)
            themePopup.lastItem?.representedObject = theme.rawValue
        }

        shellPopup.addItem(withTitle: "Login shell")
        shellPopup.lastItem?.representedObject = ""
        for shell in ["/bin/zsh", "/bin/bash", "/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/opt/homebrew/bin/bash", "/bin/sh"]
        where FileManager.default.isExecutableFile(atPath: shell) {
            shellPopup.addItem(withTitle: shell)
            shellPopup.lastItem?.representedObject = shell
        }

        for control in [fontPopup, rtlFontPopup, historyPopup, themePopup, shellPopup] as [NSControl] {
            control.target = self
            control.action = #selector(controlChanged(_:))
        }
        for control in [sizeField, sizeStepper, boldCheckbox, italicCheckbox,
                        smartRtlCheckbox, rowRtlCheckbox, optionAsMetaCheckbox] as [NSControl] {
            control.target = self
            control.action = #selector(controlChanged(_:))
        }

        let sizeRow = NSStackView(views: [sizeField, sizeStepper, boldCheckbox, italicCheckbox])
        sizeRow.spacing = 8
        preview.lineBreakMode = .byTruncatingTail

        let note = NSTextField(wrappingLabelWithString:
            "Monospaced fonts keep terminal columns aligned. The RTL font is used for Persian and Arabic words; " +
            "fonts such as Vazirmatn can be installed separately. New tabs use the selected shell.")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let grid = NSGridView(views: [
            [label("Font:"), fontPopup],
            [label("Size:"), sizeRow],
            [label("RTL font:"), rtlFontPopup],
            [label("Preview:"), preview],
            [label("History:"), historyPopup],
            [label("Theme:"), themePopup],
            [label("Shell:"), shellPopup],
            [label("Direction:"), smartRtlCheckbox],
            [NSGridCell.emptyContentView, rowRtlCheckbox],
            [label("Keyboard:"), optionAsMetaCheckbox],
            [NSGridCell.emptyContentView, note]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false
        note.widthAnchor.constraint(equalToConstant: 400).isActive = true
        fontPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        rtlFontPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
        window?.contentView = content
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func isFixedPitch(_ family: String) -> Bool {
        guard let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12) else { return false }
        return font.isFixedPitch
    }

    private func addFontItems(to popup: NSPopUpButton, recommended: [String], all: [String]) {
        if !recommended.isEmpty {
            popup.menu?.addItem(.separator())
            for family in recommended {
                popup.addItem(withTitle: family)
                popup.lastItem?.representedObject = family
            }
        }
        popup.menu?.addItem(.separator())
        for family in all where !recommended.contains(family) {
            // addItem(withTitle:) ignores duplicate titles; menu items do not.
            let item = NSMenuItem(title: family, action: nil, keyEquivalent: "")
            item.representedObject = family
            popup.menu?.addItem(item)
        }
    }

    private func select(_ popup: NSPopUpButton, _ value: AnyHashable) {
        if let item = popup.itemArray.first(where: { ($0.representedObject as? AnyHashable) == value }) {
            popup.select(item)
        } else if let value = value as? String, !value.isEmpty {
            // A font that is no longer installed still shows as selected.
            popup.addItem(withTitle: value)
            popup.lastItem?.representedObject = value
            popup.select(popup.lastItem)
        }
    }

    private func load() {
        let settings = Settings.shared
        select(fontPopup, settings.fontFamily)
        select(rtlFontPopup, settings.rtlFontFamily)
        select(historyPopup, settings.historySize)
        select(themePopup, settings.theme.rawValue)
        select(shellPopup, settings.shellPath)
        sizeField.doubleValue = settings.fontSize
        sizeStepper.doubleValue = settings.fontSize
        boldCheckbox.state = settings.bold ? .on : .off
        italicCheckbox.state = settings.italic ? .on : .off
        smartRtlCheckbox.state = settings.smartRtl ? .on : .off
        rowRtlCheckbox.state = settings.rowRtl ? .on : .off
        optionAsMetaCheckbox.state = settings.optionAsMeta ? .on : .off
        updatePreview()
    }

    private func updatePreview() {
        let settings = Settings.shared
        let text = NSMutableAttributedString(string: "سلام دنیا", attributes: [.font: settings.rtlFont ?? settings.font])
        text.append(NSAttributedString(string: " — Hello, world 123", attributes: [.font: settings.font]))
        preview.attributedStringValue = text
    }

    @objc private func controlChanged(_ sender: NSControl) {
        let settings = Settings.shared
        if sender === fontPopup {
            settings.fontFamily = fontPopup.selectedItem?.representedObject as? String ?? ""
        } else if sender === rtlFontPopup {
            settings.rtlFontFamily = rtlFontPopup.selectedItem?.representedObject as? String ?? ""
        } else if sender === historyPopup {
            settings.historySize = historyPopup.selectedItem?.representedObject as? Int ?? TerminalBuffer.defaultHistorySize
        } else if sender === themePopup {
            settings.theme = ThemePreference(rawValue: themePopup.selectedItem?.representedObject as? String ?? "") ?? .system
        } else if sender === shellPopup {
            settings.shellPath = shellPopup.selectedItem?.representedObject as? String ?? ""
        } else if sender === sizeStepper {
            settings.fontSize = sizeStepper.doubleValue
        } else if sender === sizeField {
            settings.fontSize = sizeField.doubleValue
        } else if sender === boldCheckbox {
            settings.bold = boldCheckbox.state == .on
        } else if sender === italicCheckbox {
            settings.italic = italicCheckbox.state == .on
        } else if sender === smartRtlCheckbox {
            settings.smartRtl = smartRtlCheckbox.state == .on
        } else if sender === rowRtlCheckbox {
            settings.rowRtl = rowRtlCheckbox.state == .on
        } else if sender === optionAsMetaCheckbox {
            settings.optionAsMeta = optionAsMetaCheckbox.state == .on
        }
        sizeField.doubleValue = settings.fontSize
        sizeStepper.doubleValue = settings.fontSize
        updatePreview()
    }

    override func showWindow(_ sender: Any?) {
        load()
        super.showWindow(sender)
    }
}
#endif
