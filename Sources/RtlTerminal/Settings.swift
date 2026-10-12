#if canImport(AppKit)
import AppKit
import RtlTerminalCore

enum ThemePreference: String, CaseIterable {
    case system, dark, light

    var title: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }
}

/// User preferences, stored in UserDefaults. Every change posts
/// `Settings.didChange` so open terminals update immediately.
final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("RtlTerminalSettingsDidChange")

    static let minimumFontSize = 8.0
    static let maximumFontSize = 40.0
    static let defaultFontSize = 14.0

    /// Installed terminal and programming fonts shown first in Settings.
    static let recommendedFonts = [
        "SF Mono", "Menlo", "Monaco", "JetBrains Mono", "Fira Code", "Cascadia Code",
        "Cascadia Mono", "Source Code Pro", "IBM Plex Mono", "Hack", "Iosevka",
        "DejaVu Sans Mono", "Ubuntu Mono", "Roboto Mono", "Courier New", "Andale Mono"
    ]

    /// Fonts with Persian/Arabic glyphs offered for right-to-left words.
    static let recommendedRtlFonts = [
        "Vazirmatn", "Vazir", "Sahel", "Shabnam", "Samim", "Parastoo", "IRANSans",
        "IRANSansX", "Noto Sans Arabic", "Noto Naskh Arabic", "SF Arabic", "Geeza Pro",
        "Al Nile", "Baghdad", "Damascus", "Farah", "Farisi", "Nadeem", "Sana", "Mishafi"
    ]

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.fontSize: Self.defaultFontSize,
            Key.historySize: TerminalBuffer.defaultHistorySize,
            Key.theme: ThemePreference.system.rawValue,
            Key.smartRtl: true,
            Key.rowRtl: false,
            Key.optionAsMeta: false
        ])
    }

    /// Empty means the system monospaced font (SF Mono).
    var fontFamily: String {
        get { defaults.string(forKey: Key.fontFamily) ?? "" }
        set { set(newValue, Key.fontFamily) }
    }

    var fontSize: Double {
        get { min(Self.maximumFontSize, max(Self.minimumFontSize, defaults.double(forKey: Key.fontSize))) }
        set { set(min(Self.maximumFontSize, max(Self.minimumFontSize, newValue)), Key.fontSize) }
    }

    var bold: Bool {
        get { defaults.bool(forKey: Key.bold) }
        set { set(newValue, Key.bold) }
    }

    var italic: Bool {
        get { defaults.bool(forKey: Key.italic) }
        set { set(newValue, Key.italic) }
    }

    /// Empty means automatic: the main font with system fallback.
    var rtlFontFamily: String {
        get { defaults.string(forKey: Key.rtlFontFamily) ?? "" }
        set { set(newValue, Key.rtlFontFamily) }
    }

    var historySize: Int {
        get {
            let value = defaults.integer(forKey: Key.historySize)
            return TerminalBuffer.supportedHistorySizes.contains(value) ? value : TerminalBuffer.defaultHistorySize
        }
        set { set(newValue, Key.historySize) }
    }

    var theme: ThemePreference {
        get { ThemePreference(rawValue: defaults.string(forKey: Key.theme) ?? "") ?? .system }
        set { set(newValue.rawValue, Key.theme) }
    }

    var smartRtl: Bool {
        get { defaults.bool(forKey: Key.smartRtl) }
        set { set(newValue, Key.smartRtl) }
    }

    var rowRtl: Bool {
        get { defaults.bool(forKey: Key.rowRtl) }
        set { set(newValue, Key.rowRtl) }
    }

    var optionAsMeta: Bool {
        get { defaults.bool(forKey: Key.optionAsMeta) }
        set { set(newValue, Key.optionAsMeta) }
    }

    /// Empty means the user's login shell.
    var shellPath: String {
        get { defaults.string(forKey: Key.shellPath) ?? "" }
        set { set(newValue, Key.shellPath) }
    }

    var recentDirectories: [String] {
        defaults.stringArray(forKey: Key.recentDirectories) ?? []
    }

    func rememberDirectory(_ directory: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard directory != home, directory != "/" else { return }
        let list = [directory] + recentDirectories.filter { $0 != directory }
        defaults.set(Array(list.prefix(10)), forKey: Key.recentDirectories)
    }

    func clearRecentDirectories() {
        defaults.removeObject(forKey: Key.recentDirectories)
    }

    // MARK: - Derived values

    var font: NSFont {
        let size = CGFloat(fontSize)
        var font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        if !fontFamily.isEmpty,
           let chosen = NSFontManager.shared.font(withFamily: fontFamily, traits: [], weight: 5, size: size)
            ?? NSFont(name: fontFamily, size: size) {
            font = chosen
        }
        if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    var rtlFont: NSFont? {
        guard !rtlFontFamily.isEmpty else { return nil }
        return NSFontManager.shared.font(
            withFamily: rtlFontFamily, traits: [], weight: 5, size: CGFloat(fontSize))
    }

    /// Shell executable for new sessions.
    var resolvedShell: String {
        if !shellPath.isEmpty, FileManager.default.isExecutableFile(atPath: shellPath) { return shellPath }
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"],
           FileManager.default.isExecutableFile(atPath: shell) { return shell }
        return "/bin/zsh"
    }

    func terminalTheme(for appearance: NSAppearance) -> TerminalTheme {
        switch theme {
        case .dark: return .dark
        case .light: return .light
        case .system:
            return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        }
    }

    private func set(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private enum Key {
        static let fontFamily = "FontFamily"
        static let fontSize = "FontSize"
        static let bold = "FontBold"
        static let italic = "FontItalic"
        static let rtlFontFamily = "RtlFontFamily"
        static let historySize = "HistorySize"
        static let theme = "Theme"
        static let smartRtl = "SmartRtl"
        static let rowRtl = "RowRtl"
        static let optionAsMeta = "OptionAsMeta"
        static let shellPath = "ShellPath"
        static let recentDirectories = "RecentDirectories"
    }
}
#endif
