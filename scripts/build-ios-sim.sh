#!/bin/sh
# Unsigned simulator build of the iOS app, to check it compiles (npm run build:ios-sim). Output goes in .build/.
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/ios/App"
exec xcodebuild -project App.xcodeproj -scheme App -configuration Debug \
  -sdk iphonesimulator -destination "generic/platform=iOS Simulator" \
  -derivedDataPath "$root/.build/DerivedData" \
  -clonedSourcePackagesDirPath "$root/.build/spm-packages" \
  -packageCachePath "$root/.build/spm-cache" \
  CODE_SIGNING_ALLOWED=NO build "$@"
