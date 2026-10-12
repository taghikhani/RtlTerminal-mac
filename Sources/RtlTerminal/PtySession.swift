#if canImport(AppKit)
import Darwin
import Foundation

/// A shell running on a pseudo terminal (the macOS counterpart of ConPTY).
final class PtySession {
    enum Failure: Error {
        case forkFailed(Int32)
    }

    let pid: pid_t
    let shellPath: String
    private let fd: Int32
    private let readQueue = DispatchQueue(label: "RtlTerminal.pty.read")
    private let writeQueue = DispatchQueue(label: "RtlTerminal.pty.write")
    private var readSource: DispatchSourceRead?
    private var exited = false

    /// Called on a background queue with each chunk of output.
    var onOutput: ((UnsafeBufferPointer<UInt8>) -> Void)?
    /// Called on the main queue once the shell has exited.
    var onExit: (() -> Void)?

    init(shell: String, directory: String?, columns: Int, rows: Int, version: String) throws {
        shellPath = shell

        // Everything the child needs is prepared before fork(): after fork only
        // async-signal-safe calls are allowed until execve().
        let shellName = (shell as NSString).lastPathComponent
        let arguments = ["-" + shellName]   // login shell, like Terminal.app
        let environment = Self.environment(version: version)
            .map { "\($0.key)=\($0.value)" }
        let path = strdup(shell)
        let argv = Self.cStringArray(arguments)
        let envp = Self.cStringArray(environment)
        let workingDirectory = directory.flatMap { strdup($0) }
        defer {
            free(path)
            free(workingDirectory)
            Self.freeCStringArray(argv, count: arguments.count)
            Self.freeCStringArray(envp, count: environment.count)
        }

        var master: Int32 = -1
        var size = winsize(
            ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns),
            ws_xpixel: 0, ws_ypixel: 0)
        let child = forkpty(&master, nil, nil, &size)

        if child < 0 { throw Failure.forkFailed(errno) }

        if child == 0 {
            if let workingDirectory { _ = chdir(workingDirectory) }
            // Let the line discipline erase whole UTF-8 characters (Persian
            // text in canonical mode), as Terminal.app does.
            var attributes = termios()
            if tcgetattr(STDIN_FILENO, &attributes) == 0 {
                attributes.c_iflag |= tcflag_t(IUTF8)
                _ = tcsetattr(STDIN_FILENO, TCSANOW, &attributes)
            }
            _ = execve(path, argv, envp)
            _exit(127)
        }

        pid = child
        fd = master
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        let fd = fd
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        source.setEventHandler { [weak self] in
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                buffer.withUnsafeBufferPointer { pointer in
                    self?.onOutput?(UnsafeBufferPointer(rebasing: pointer[0..<count]))
                }
            } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                // EOF or EIO: every process holding the terminal has gone.
                self?.readSource?.cancel()
            }
        }
        source.setCancelHandler { [weak self] in
            close(fd)
            self?.reap()
        }
        readSource = source
        source.resume()
    }

    func write(_ text: String) {
        write(Array(text.utf8))
    }

    func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let fd = fd
        writeQueue.async {
            var offset = 0
            while offset < bytes.count {
                let written = bytes.withUnsafeBufferPointer {
                    Darwin.write(fd, $0.baseAddress! + offset, $0.count - offset)
                }
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    func resize(columns: Int, rows: Int) {
        var size = winsize(
            ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns),
            ws_xpixel: 0, ws_ypixel: 0)
        // TIOCSWINSZ is a function-like macro that Swift does not import.
        let setWindowSize: UInt = 0x8008_7467
        _ = withUnsafeMutablePointer(to: &size) { ioctl(fd, setWindowSize, $0) }
    }

    /// Hangs up the shell; the PTY is closed once its processes exit.
    func terminate() {
        guard !exited else { return }
        kill(pid, SIGHUP)
        let pid = pid
        // Processes that ignore SIGHUP are closed after a grace period.
        readQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.exited else { return }
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
            self.readSource?.cancel()
        }
    }

    /// True while a program other than the shell runs in the foreground.
    var hasForegroundJob: Bool {
        guard !exited else { return false }
        let group = tcgetpgrp(fd)
        return group > 0 && group != pid
    }

    /// Working directory of the shell, for new tabs and recent directories.
    var currentDirectory: String? {
        guard !exited else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    private func reap() {
        let pid = pid
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            DispatchQueue.main.async {
                self?.exited = true
                self?.onExit?()
            }
        }
    }

    private static func environment(version: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "RtlTerminal"
        environment["TERM_PROGRAM_VERSION"] = version
        // Apps started from Finder get no locale; without UTF-8 the shell
        // would show Persian input as escape sequences.
        if environment["LANG"] == nil && environment["LC_ALL"] == nil && environment["LC_CTYPE"] == nil {
            environment["LANG"] = "en_US.UTF-8"
        }
        if environment["HOME"] == nil { environment["HOME"] = NSHomeDirectory() }
        if environment["USER"] == nil {
            environment["USER"] = NSUserName()
            environment["LOGNAME"] = NSUserName()
        }
        environment.removeValue(forKey: "TERM_SESSION_ID")
        return environment
    }

    private static func cStringArray(_ strings: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
        let array = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() { array[index] = strdup(string) }
        array[strings.count] = nil
        return array
    }

    private static func freeCStringArray(_ array: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, count: Int) {
        for index in 0..<count { free(array[index]) }
        array.deallocate()
    }
}
#endif
