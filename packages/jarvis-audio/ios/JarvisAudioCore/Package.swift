// swift-tools-version: 5.9
import PackageDescription

// The plugin's plain-Swift logic, also linked into the JarvisWidget extension. No Capacitor or LiveKit, so
// `swift test` runs on the Mac with nothing to fetch.
let package = Package(
    name: "JarvisAudioCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "JarvisAudioCore", targets: ["JarvisAudioCore"]),
    ],
    targets: [
        .target(name: "JarvisAudioCore"),
        .testTarget(name: "JarvisAudioCoreTests", dependencies: ["JarvisAudioCore"]),
    ]
)
