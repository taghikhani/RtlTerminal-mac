#if canImport(AppKit)
import AppKit
import RtlTerminalCore
import UniformTypeIdentifiers

/// One terminal tab: a window (grouped with others by native macOS window
/// tabs) that owns a shell session, its screen buffer and view.
final class TerminalWindowController: NSWindowController, NSWindowDelegate, TerminalViewDelegate {
    let terminalView: TerminalView
    private let scrollView: NSScrollView
    private let buffer: TerminalBuffer
    private var session: PtySession?
    private let renderScheduler = RenderScheduler()
    private var lastRenderedRevision = -1
    private var synchronizedSince: Date?
    private var resizeWork: DispatchWorkItem?
    private var gridSize = (columns: 0, rows: 0)
    private var closeConfirmed = false
    private var appliedFont: NSFont?
    private var appliedRtlFont: NSFont?
    private let shellName: String

    /// Called after the window closed, so the app can release the controller.
    var onClose: ((TerminalWindowController) -> Void)?

    var currentDirectory: String? { session?.currentDirectory }
    var hasRunningJob: Bool { session?.hasForegroundJob ?? false }

    init() {
        let settings = Settings.shared
        terminalView = TerminalView(frame: .zero)
        terminalView.applyFont(settings.font, rtlFont: settings.rtlFont)
        shellName = (settings.resolvedShell as NSString).lastPathComponent

        let contentSize = NSSize(
            width: (terminalView.cellWidth * 100 + TerminalView.inset * 2).rounded(.up),
            height: (terminalView.lineHeight * 30).rounded(.up))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "RtlTerminal"
        window.contentMinSize = NSSize(width: 320, height: 160)
        window.title = shellName
        window.isReleasedWhenClosed = false

        scrollView = NSScrollView(frame: NSRect(origin: .zero, size: contentSize))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autoresizingMask = [.width, .height]
        scrollView.verticalScrollElasticity = .none
        terminalView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        terminalView.autoresizingMask = [.width]
        scrollView.documentView = terminalView
        window.contentView = scrollView
        window.initialFirstResponder = terminalView

        buffer = TerminalBuffer(columns: 100, rows: 30, maximumScrollbackRows: settings.historySize)
        buffer.versionString = AppInfo.version

        super.init(window: window)

        renderScheduler.onRender = { [weak self] in self?.render() }
        window.delegate = self
        terminalView.delegate = self
        applySettings()
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsDidChange), name: Settings.didChange, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Session

    func start(directory: String?) {
        window?.makeFirstResponder(terminalView)
        window?.layoutIfNeeded()
        terminalView.updateDocumentSize()
        let grid = computeGridSize()
        gridSize = grid
        buffer.resize(columns: grid.columns, rows: grid.rows)

        var isDirectory: ObjCBool = false
        let directory = directory.flatMap {
            FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue ? $0 : nil
        } ?? NSHomeDirectory()

        do {
            let session = try PtySession(
                shell: Settings.shared.resolvedShell,
                directory: directory,
                columns: grid.columns,
                rows: grid.rows,
                version: AppInfo.version)
            // Output is parsed on the PTY queue; the UI only takes snapshots.
            let buffer = buffer
            let scheduler = renderScheduler
            session.onOutput = { [weak session] bytes in
                let responses = buffer.process(bytes: bytes)
                for response in responses { session?.write(response) }
                scheduler.schedule()
            }
            session.onExit = { [weak self] in
                // The tab closes when its shell exits, as in Terminal.app.
                self?.closeConfirmed = true
                self?.window?.close()
            }
            self.session = session
            session.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not start the shell"
            alert.informativeText = "\(Settings.shared.resolvedShell): \(error)"
            alert.runModal()
        }
    }

    private func send(_ text: String) {
        session?.write(text)
    }

    // MARK: - Rendering

    private func scheduleRender() {
        renderScheduler.schedule()
    }

    private func render() {
        let snapshot = buffer.snapshot()
        // Synchronized output (mode 2026): wait for the frame to complete,
        // but never freeze the screen for more than a quarter second.
        if snapshot.modes.synchronizedOutput {
            let since = synchronizedSince ?? Date()
            synchronizedSince = since
            if Date().timeIntervalSince(since) < 0.25 {
                scheduleRender()
                return
            }
        } else {
            synchronizedSince = nil
        }

        guard snapshot.revision != lastRenderedRevision else { return }
        lastRenderedRevision = snapshot.revision
        terminalView.present(snapshot)
        let title = snapshot.title ?? defaultTitle
        if window?.title != title { window?.title = title }
    }

    private var defaultTitle: String {
        guard let directory = session?.currentDirectory else { return shellName }
        let name = directory == NSHomeDirectory() ? "~" : (directory as NSString).lastPathComponent
        return "\(name) — \(shellName)"
    }

    // MARK: - Size

    private func computeGridSize() -> (columns: Int, rows: Int) {
        let size = scrollView.contentView.bounds.size
        let columns = Int((size.width - 2 * TerminalView.inset) / terminalView.cellWidth)
        let rows = Int(size.height / terminalView.lineHeight)
        return (max(10, columns), max(5, rows))
    }

    private func queueResize() {
        terminalView.updateDocumentSize()
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyResize() }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(40), execute: work)
    }

    private func applyResize() {
        let grid = computeGridSize()
        guard grid != gridSize else { return }
        gridSize = grid
        buffer.resize(columns: grid.columns, rows: grid.rows)
        session?.resize(columns: grid.columns, rows: grid.rows)
        terminalView.invalidateLayouts()
        lastRenderedRevision = -1
        render()
    }

    func windowDidResize(_ notification: Notification) {
        queueResize()
    }

    // MARK: - Settings

    @objc private func settingsDidChange() {
        applySettings()
    }

    private func applySettings() {
        let settings = Settings.shared
        let font = settings.font
        let rtlFont = settings.rtlFont
        if font != appliedFont || rtlFont != appliedRtlFont {
            appliedFont = font
            appliedRtlFont = rtlFont
            terminalView.applyFont(font, rtlFont: rtlFont)
            if session != nil { queueResize() }
        }
        terminalView.setDirection(smartRtl: settings.smartRtl, rowRtl: settings.rowRtl)
        terminalView.optionAsMeta = settings.optionAsMeta
        buffer.setMaximumScrollbackRows(settings.historySize)
        terminalView.refreshTheme()
        lastRenderedRevision = -1
        if session != nil { scheduleRender() }
    }

    // MARK: - TerminalViewDelegate

    func terminalView(_ view: TerminalView, send text: String) {
        send(text)
    }

    func terminalViewThemeDidChange(_ view: TerminalView) {
        let theme = view.theme
        // Applications that query the default colors (OSC 10/11) get these.
        buffer.defaultForeground = theme.defaultForeground
        buffer.defaultBackground = theme.defaultBackground
        let background = theme.defaultBackground
        scrollView.backgroundColor = NSColor(
            srgbRed: CGFloat(background.red) / 255, green: CGFloat(background.green) / 255,
            blue: CGFloat(background.blue) / 255, alpha: 1)
        scrollView.scrollerKnobStyle = theme == .dark ? .light : .dark
    }

    func terminalViewApplicationIsRunning(_ view: TerminalView) -> Bool {
        hasRunningJob
    }

    func terminalViewResetStaleMouseModes(_ view: TerminalView) {
        if buffer.resetMouseReporting() { scheduleRender() }
    }

    // MARK: - Window

    func windowDidBecomeKey(_ notification: Notification) {
        terminalView.isWindowKey = true
        if terminalView.snapshot?.modes.focusReporting == true, focusReportingIsLive() { send("\u{1b}[I") }
    }

    func windowDidResignKey(_ notification: Notification) {
        terminalView.isWindowKey = false
        if terminalView.snapshot?.modes.focusReporting == true, focusReportingIsLive() { send("\u{1b}[O") }
    }

    /// Focus reports left enabled by an exited program would be typed into the shell.
    private func focusReportingIsLive() -> Bool {
        guard hasRunningJob else {
            if buffer.resetMouseReporting() { scheduleRender() }
            return false
        }
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !closeConfirmed, hasRunningJob else { return true }
        let alert = NSAlert()
        alert.messageText = "Close this terminal?"
        alert.informativeText = "A program is still running in this tab. Closing it will end the program."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.closeConfirmed = true
            sender.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if let directory = session?.currentDirectory { Settings.shared.rememberDirectory(directory) }
        session?.terminate()
        NotificationCenter.default.removeObserver(self)
        onClose?(self)
    }

    // MARK: - Actions

    @objc func clearScrollback(_ sender: Any?) {
        buffer.clearScrollback()
        terminalView.clearSelection()
        // Let the shell redraw its prompt at the top, like Terminal.app.
        if terminalView.snapshot?.modes.alternateScreen == false { send("\u{0c}") }
        lastRenderedRevision = -1
        render()
    }

    @objc func exportSession(_ sender: Any?) {
        guard let window else { return }
        let text = buffer.snapshot().plainText
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "RtlTerminal-session-\(formatter.string(from: Date())).txt"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}

/// Coalesces bursts of PTY output into one render per display frame.
/// Called from the PTY queue; renders on the main queue.
private final class RenderScheduler: @unchecked Sendable {
    var onRender: (() -> Void)?
    private let lock = NSLock()
    private var scheduled = false

    func schedule() {
        lock.lock()
        defer { lock.unlock() }
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(8)) { [self] in
            lock.lock()
            scheduled = false
            lock.unlock()
            onRender?()
        }
    }
}
#endif
