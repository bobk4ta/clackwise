// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "clackwise",
    platforms: [.macOS(.v14)],
    targets: [
        // Shared by the CLI and the app: sensor, clocks, impact detection, velocity mapping,
        // sound packs, audio engine, aggregate stats.
        .target(
            name: "ClackwiseCore",
            path: "Sources/ClackwiseCore",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("AVFoundation"),
                             .linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox")]
        ),
        .executableTarget(
            name: "keyimpact",
            dependencies: ["ClackwiseCore"],
            path: "Sources/keyimpact",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("ApplicationServices")]
        ),
        .executableTarget(
            name: "Clackwise",
            dependencies: ["ClackwiseCore"],
            path: "Sources/Clackwise",
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ApplicationServices"),
                             .linkedFramework("Carbon")]
        ),
    ]
)
