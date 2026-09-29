// swift-tools-version: 6.0
// For editors and `swift build`; `make` builds the universal release binary.

import PackageDescription

let package = Package(
    name: "SleepWatcher",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "sleepwatcher", path: "Sources/sleepwatcher"),
    ]
)
