#!/bin/sh
# Builds the iOS app for the simulator without signing, to check that everything compiles:
# npm run build:ios-sim. Build output goes in .build/ (DerivedData and SwiftPM checkouts).
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/ios/App"
exec xcodebuild -project App.xcodeproj -scheme App -configuration Debug \
  -sdk iphonesimulator -destination "generic/platform=iOS Simulator" \
  -derivedDataPath "$root/.build/DerivedData" \
  -clonedSourcePackagesDirPath "$root/.build/spm-packages" \
  -packageCachePath "$root/.build/spm-cache" \
  CODE_SIGNING_ALLOWED=NO build "$@"
