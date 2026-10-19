#!/bin/sh
# The Swift unit tests without SwiftPM (swiftc builds AlfredAudioCore and an XCTest bundle, xctest runs it), for
# where `swift test` can't write its build folder. $1: build dir (default .build/direct).
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
core="$root/packages/alfred-audio/ios/AlfredAudioCore"
out="${1:-$root/.build/direct}"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
platform="$(xcrun --sdk macosx --show-sdk-platform-path)"
frameworks="$platform/Developer/Library/Frameworks"
target="$(uname -m)-apple-macosx14.0"
mkdir -p "$out/cache" "$out/AlfredAudioCoreTests.xctest/Contents/MacOS"

xcrun swiftc -sdk "$sdk" -target "$target" -module-cache-path "$out/cache" -enable-testing \
  -module-name AlfredAudioCore -emit-library -emit-module -emit-module-path "$out/AlfredAudioCore.swiftmodule" \
  -o "$out/libAlfredAudioCore.dylib" -Xlinker -install_name -Xlinker @rpath/libAlfredAudioCore.dylib \
  "$core"/Sources/AlfredAudioCore/*.swift

xcrun swiftc -sdk "$sdk" -target "$target" -module-cache-path "$out/cache" -I "$out" -L "$out" -lAlfredAudioCore \
  -F "$frameworks" -I "$platform/Developer/usr/lib" -L "$platform/Developer/usr/lib" -framework XCTest -Xlinker -bundle -Xlinker -rpath -Xlinker "$out" \
  -Xlinker -rpath -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$platform/Developer/usr/lib" \
  -o "$out/AlfredAudioCoreTests.xctest/Contents/MacOS/AlfredAudioCoreTests" \
  "$core"/Tests/AlfredAudioCoreTests/*.swift

cat > "$out/AlfredAudioCoreTests.xctest/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AlfredAudioCoreTests</string>
<key>CFBundleIdentifier</key><string>com.anil.alfred.AlfredAudioCoreTests</string>
<key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
EOF

exec xcrun xctest "$out/AlfredAudioCoreTests.xctest"
