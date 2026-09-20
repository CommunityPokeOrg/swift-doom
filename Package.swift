// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "swift-doom",
    products: [
        .library(name: "DoomEngine", targets: ["DoomEngine"]),
        .library(name: "DoomPlatform", targets: ["DoomPlatform"]),
        // Dynamic so that runtime-compiled mod scripts can link against it.
        .library(name: "DoomScripting", type: .dynamic, targets: ["DoomScripting"]),
        .executable(name: "doom-swift", targets: ["doom-swift"]),
    ],
    targets: [
        .target(
            name: "DoomEngine",
            dependencies: []
        ),
        .target(
            name: "DoomPlatform",
            dependencies: ["DoomEngine"]
        ),
        .target(
            name: "DoomScripting",
            dependencies: ["DoomEngine"]
        ),
        .executableTarget(
            name: "doom-swift",
            dependencies: ["DoomEngine", "DoomPlatform", "DoomScripting"]
        ),
        .testTarget(
            name: "DoomEngineTests",
            dependencies: ["DoomEngine", "DoomPlatform"]
        ),
        .testTarget(
            name: "DoomScriptingTests",
            dependencies: ["DoomScripting", "DoomEngine"]
        ),
    ]
)
