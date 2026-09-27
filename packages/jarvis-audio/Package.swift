// swift-tools-version: 5.9
import PackageDescription

// The JarvisAudio Capacitor plugin for iOS. `npx cap sync` adds it to ios/App/CapApp-SPM by this name.
// Its plain-Swift logic is the JarvisAudioCore package next to it, tested on its own (npm run test:ios).
let package = Package(
    name: "JarvisAudio",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "JarvisAudio", targets: ["JarvisAudioPlugin"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "7.0.0"),
        .package(url: "https://github.com/livekit/client-sdk-swift.git", from: "2.17.0"),
        .package(name: "JarvisAudioCore", path: "ios/JarvisAudioCore"),
    ],
    targets: [
        .target(
            name: "JarvisAudioPlugin",
            dependencies: [
                .product(name: "JarvisAudioCore", package: "JarvisAudioCore"),
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm"),
                .product(name: "LiveKit", package: "client-sdk-swift"),
            ],
            path: "ios/Sources/JarvisAudioPlugin"
        ),
    ]
)
