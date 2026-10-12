#if canImport(AppKit)
import AppKit
import RtlTerminalCore

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private var controllers: [TerminalWindowController] = []
    private var settingsWindow: SettingsWindowController?
    private var guideWindow: GuideWindowController?
    private let recentMenu = NSMenu(title: "Open Recent Directory")
    private var openedFromLaunch = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        // Needed when run unbundled (`swift run`); a no-op inside the .app.
        NSApp.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = true
        NSApp.mainMenu = buildMainMenu()
        applyAppearance()
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsDidChange), name: Settings.didChange, object: nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        if !openedFromLaunch { openWindow(directory: nil, asTab: false) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openWindow(directory: nil, asTab: false) }
        return true
    }

    /// Folders dropped on the Dock icon or opened with `open -a RtlTerminal`.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            let directory = isDirectory.boolValue ? url.path : url.deletingLastPathComponent().path
            openWindow(directory: directory, asTab: !controllers.isEmpty)
            openedFromLaunch = true
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controllers.contains(where: \.hasRunningJob) else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit RtlTerminal?"
        alert.informativeText = "Programs are still running in some tabs. Quitting will end them."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        for controller in controllers {
            if let directory = controller.currentDirectory { Settings.shared.rememberDirectory(directory) }
        }
        for file in TerminalView.temporaryFiles { try? FileManager.default.removeItem(at: file) }
    }

    // MARK: - Windows and tabs

    @discardableResult
    private func openWindow(directory: String?, asTab: Bool) -> TerminalWindowController {
        let current = activeController?.window
        let directory = directory ?? (asTab ? activeDirectory : nil)
        let controller = TerminalWindowController()
        controller.onClose = { [weak self] closed in
            self?.controllers.removeAll { $0 === closed }
        }
        controllers.append(controller)

        guard let window = controller.window else { return controller }
        if asTab, let current {
            current.addTabbedWindow(window, ordered: .above)
        } else if let current {
            window.setFrame(current.frame.offsetBy(dx: 24, dy: -24), display: false)
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        controller.start(directory: directory)
        return controller
    }

    private var activeController: TerminalWindowController? {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        return controllers.first { $0.window === window } ?? controllers.last
    }

    private var activeDirectory: String? { activeController?.currentDirectory }

    @objc func newWindow(_ sender: Any?) {
        openWindow(directory: nil, asTab: false)
    }

    @objc func newTab(_ sender: Any?) {
        openWindow(directory: activeDirectory, asTab: !controllers.isEmpty)
    }

    /// The "+" button in the native tab bar.
    @objc func newWindowForTab(_ sender: Any?) {
        newTab(sender)
    }

    @objc private func openRecentDirectory(_ sender: NSMenuItem) {
        guard let directory = sender.representedObject as? String else { return }
        openWindow(directory: directory, asTab: !controllers.isEmpty)
    }

    @objc private func clearRecentDirectories(_ sender: Any?) {
        Settings.shared.clearRecentDirectories()
    }

    /// Finder → Services → "New RtlTerminal Tab at Folder".
    @objc func openFolderService(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        for url in urls {
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            openWindow(
                directory: isDirectory.boolValue ? url.path : url.deletingLastPathComponent().path,
                asTab: !controllers.isEmpty)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - View options

    @objc private func toggleSmartRtl(_ sender: Any?) {
        Settings.shared.smartRtl.toggle()
    }

    @objc private func toggleRowRtl(_ sender: Any?) {
        Settings.shared.rowRtl.toggle()
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let theme = ThemePreference(rawValue: raw) else { return }
        Settings.shared.theme = theme
    }

    @objc private func biggerFont(_ sender: Any?) {
        Settings.shared.fontSize += 1
    }

    @objc private func smallerFont(_ sender: Any?) {
        Settings.shared.fontSize -= 1
    }

    @objc private func actualSizeFont(_ sender: Any?) {
        Settings.shared.fontSize = Settings.defaultFontSize
    }

    @objc private func settingsDidChange() {
        applyAppearance()
    }

    private func applyAppearance() {
        switch Settings.shared.theme {
        case .system: NSApp.appearance = nil
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        }
    }

    @objc private func showSettings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func showGuide(_ sender: Any?) {
        if guideWindow == nil { guideWindow = GuideWindowController() }
        guideWindow?.showWindow(nil)
        guideWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openProjectPage(_ sender: Any?) {
        if let url = URL(string: "https://github.com/mirbehnam/RtlTerminal") { NSWorkspace.shared.open(url) }
    }

    @objc private func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(
            string: "macOS port of Rtl Terminal by behnamapps.\nPersian, Arabic and right-to-left text in the terminal.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Rtl Terminal",
            .credits: credits
        ])
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let settings = Settings.shared
        switch menuItem.action {
        case #selector(toggleSmartRtl(_:)):
            menuItem.state = settings.smartRtl ? .on : .off
        case #selector(toggleRowRtl(_:)):
            menuItem.state = settings.rowRtl ? .on : .off
        case #selector(selectTheme(_:)):
            menuItem.state = (menuItem.representedObject as? String) == settings.theme.rawValue ? .on : .off
        case #selector(biggerFont(_:)):
            return settings.fontSize < Settings.maximumFontSize
        case #selector(smallerFont(_:)):
            return settings.fontSize > Settings.minimumFontSize
        default:
            break
        }
        return true
    }

    // MARK: - Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let directories = Settings.shared.recentDirectories
        for directory in directories {
            let item = NSMenuItem(
                title: (directory as NSString).abbreviatingWithTildeInPath,
                action: #selector(openRecentDirectory(_:)), keyEquivalent: "")
            item.representedObject = directory
            item.target = self
            menu.addItem(item)
        }
        if directories.isEmpty {
            let empty = NSMenuItem(title: "No Recent Directories", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            menu.addItem(.separator())
            let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearRecentDirectories(_:)), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }
    }

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = submenu(main, "Rtl Terminal")
        item(app, "About Rtl Terminal", #selector(showAbout(_:)), target: self)
        app.addItem(.separator())
        item(app, "Settings…", #selector(showSettings(_:)), ",", target: self)
        app.addItem(.separator())
        let services = NSMenu(title: "Services")
        app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        item(app, "Hide Rtl Terminal", #selector(NSApplication.hide(_:)), "h")
        item(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        item(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        item(app, "Quit Rtl Terminal", #selector(NSApplication.terminate(_:)), "q")

        let shell = submenu(main, "Shell")
        item(shell, "New Window", #selector(newWindow(_:)), "n", target: self)
        item(shell, "New Tab", #selector(newTab(_:)), "t", target: self)
        recentMenu.delegate = self
        shell.addItem(withTitle: "Open Recent Directory", action: nil, keyEquivalent: "").submenu = recentMenu
        shell.addItem(.separator())
        item(shell, "Export Session…", #selector(TerminalWindowController.exportSession(_:)), "s")
        shell.addItem(.separator())
        item(shell, "Close Tab", #selector(NSWindow.performClose(_:)), "w")

        let edit = submenu(main, "Edit")
        item(edit, "Copy", #selector(TerminalView.copy(_:)), "c")
        item(edit, "Paste", #selector(TerminalView.paste(_:)), "v")
        item(edit, "Select All", #selector(TerminalView.selectAll(_:)), "a")
        edit.addItem(.separator())
        item(edit, "Clear Scrollback", #selector(TerminalWindowController.clearScrollback(_:)), "k")

        let view = submenu(main, "View")
        item(view, "Smart RTL", #selector(toggleSmartRtl(_:)), "r", [.command, .shift], target: self)
        item(view, "Row RTL", #selector(toggleRowRtl(_:)), "r", [.command, .option], target: self)
        view.addItem(.separator())
        let themes = NSMenu(title: "Theme")
        view.addItem(withTitle: "Theme", action: nil, keyEquivalent: "").submenu = themes
        for theme in ThemePreference.allCases {
            let themeItem = item(themes, theme.title, #selector(selectTheme(_:)), target: self)
            themeItem.representedObject = theme.rawValue
        }
        view.addItem(.separator())
        item(view, "Bigger", #selector(biggerFont(_:)), "+", target: self)
        item(view, "Bigger", #selector(biggerFont(_:)), "=", target: self)
        item(view, "Smaller", #selector(smallerFont(_:)), "-", target: self)
        item(view, "Actual Size", #selector(actualSizeFont(_:)), "0", target: self)
        view.addItem(.separator())
        item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        // Keep only one visible "Bigger" item; the second just adds Cmd+=.
        if let hidden = view.items.first(where: { $0.keyEquivalent == "=" }) {
            hidden.isHidden = true
            hidden.allowsKeyEquivalentWhenHidden = true
        }

        let windowMenu = submenu(main, "Window")
        item(windowMenu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        item(windowMenu, "Zoom", #selector(NSWindow.performZoom(_:)))
        windowMenu.addItem(.separator())
        item(windowMenu, "Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "[", [.command, .shift])
        item(windowMenu, "Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "]", [.command, .shift])
        windowMenu.addItem(.separator())
        item(windowMenu, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = windowMenu

        let help = submenu(main, "Help")
        item(help, "Rtl Terminal Guide", #selector(showGuide(_:)), "?", target: self)
        item(help, "Original Project on GitHub", #selector(openProjectPage(_:)), target: self)
        NSApp.helpMenu = help

        return main
    }

    private func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        return menu
    }

    @discardableResult
    private func item(
        _ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }
}
#endif
