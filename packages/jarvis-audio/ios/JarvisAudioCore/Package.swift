// swift-tools-version: 5.9
import PackageDescription

// The plugin's plain-Swift logic: server addresses, token replies, push registration, reconnect timing,
// earphone debouncing, captions and the chime. No Capacitor or LiveKit, so `swift test` here runs on the Mac with nothing to fetch.
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
