// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RtlTerminal",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "RtlTerminal", targets: ["RtlTerminal"]),
        .library(name: "RtlTerminalCore", targets: ["RtlTerminalCore"])
    ],
    targets: [
        // Terminal emulation, Smart RTL and row layout. Foundation only, so it
        // builds and is tested on Linux as well as macOS.
        .target(name: "RtlTerminalCore"),
        // AppKit user interface, PTY and CoreText renderer (macOS only).
        .executableTarget(
            name: "RtlTerminal",
            dependencies: ["RtlTerminalCore"]),
        .testTarget(
            name: "RtlTerminalCoreTests",
            dependencies: ["RtlTerminalCore"])
    ]
)
