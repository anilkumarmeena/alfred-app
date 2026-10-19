// swift-tools-version: 5.9
import PackageDescription

// `npx cap sync` adds this plugin to ios/App/CapApp-SPM by this name. Plain-Swift logic lives in AlfredAudioCore
// (npm run test:ios).
let package = Package(
    name: "AlfredAudio",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "AlfredAudio", targets: ["AlfredAudioPlugin"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "7.0.0"),
        .package(url: "https://github.com/livekit/client-sdk-swift.git", from: "2.17.0"),
        .package(name: "AlfredAudioCore", path: "ios/AlfredAudioCore"),
    ],
    targets: [
        .target(
            name: "AlfredAudioPlugin",
            dependencies: [
                .product(name: "AlfredAudioCore", package: "AlfredAudioCore"),
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm"),
                .product(name: "LiveKit", package: "client-sdk-swift"),
            ],
            path: "ios/Sources/AlfredAudioPlugin"
        ),
    ]
)
