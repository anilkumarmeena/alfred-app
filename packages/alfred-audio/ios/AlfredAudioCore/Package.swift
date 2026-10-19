// swift-tools-version: 5.9
import PackageDescription

// The plugin's plain-Swift logic, also linked into the AlfredWidget extension. No Capacitor or LiveKit, so
// `swift test` runs on the Mac with nothing to fetch.
let package = Package(
    name: "AlfredAudioCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AlfredAudioCore", targets: ["AlfredAudioCore"]),
    ],
    targets: [
        .target(name: "AlfredAudioCore"),
        .testTarget(name: "AlfredAudioCoreTests", dependencies: ["AlfredAudioCore"]),
    ]
)
