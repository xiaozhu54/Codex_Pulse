// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CodexPulse",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CodexPulseCore", targets: ["CodexPulseCore"]),
        .executable(name: "CodexPulseBehaviorTests", targets: ["CodexPulseBehaviorTests"]),
        .executable(name: "CodexPulseApp", targets: ["CodexPulseApp"]),
        .executable(name: "CodexPulseMonitor", targets: ["CodexPulseMonitor"])
    ],
    targets: [
        .target(
            name: "CodexPulseCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "CodexPulseBehaviorTests",
            dependencies: ["CodexPulseCore"],
            path: "Tests/CodexPulseCoreTests"
        ),
        .executableTarget(
            name: "CodexPulseApp",
            dependencies: ["CodexPulseCore"]
        ),
        .executableTarget(name: "CodexPulseMonitor")
    ]
)
