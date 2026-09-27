#!/bin/sh
# The Swift unit tests without SwiftPM: swiftc builds JarvisAudioCore and an XCTest bundle, and xctest runs it.
# For machines or sandboxes where `swift test` can't write its build folder. OUT (default .build/direct) holds the build.
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
core="$root/packages/jarvis-audio/ios/JarvisAudioCore"
out="${1:-$root/.build/direct}"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
platform="$(xcrun --sdk macosx --show-sdk-platform-path)"
frameworks="$platform/Developer/Library/Frameworks"
target="$(uname -m)-apple-macosx14.0"
mkdir -p "$out/cache" "$out/JarvisAudioCoreTests.xctest/Contents/MacOS"

xcrun swiftc -sdk "$sdk" -target "$target" -module-cache-path "$out/cache" -enable-testing \
  -module-name JarvisAudioCore -emit-library -emit-module -emit-module-path "$out/JarvisAudioCore.swiftmodule" \
  -o "$out/libJarvisAudioCore.dylib" -Xlinker -install_name -Xlinker @rpath/libJarvisAudioCore.dylib \
  "$core"/Sources/JarvisAudioCore/*.swift

xcrun swiftc -sdk "$sdk" -target "$target" -module-cache-path "$out/cache" -I "$out" -L "$out" -lJarvisAudioCore \
  -F "$frameworks" -I "$platform/Developer/usr/lib" -L "$platform/Developer/usr/lib" -framework XCTest -Xlinker -bundle -Xlinker -rpath -Xlinker "$out" \
  -Xlinker -rpath -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$platform/Developer/usr/lib" \
  -o "$out/JarvisAudioCoreTests.xctest/Contents/MacOS/JarvisAudioCoreTests" \
  "$core"/Tests/JarvisAudioCoreTests/*.swift

cat > "$out/JarvisAudioCoreTests.xctest/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>JarvisAudioCoreTests</string>
<key>CFBundleIdentifier</key><string>com.anil.jarvis.JarvisAudioCoreTests</string>
<key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
EOF

exec xcrun xctest "$out/JarvisAudioCoreTests.xctest"
