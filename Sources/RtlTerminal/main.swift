#if canImport(AppKit)
import AppKit

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
#else
print("RtlTerminal's user interface requires macOS.")
#endif
