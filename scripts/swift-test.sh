#!/bin/sh
# Runs the plugin's Swift unit tests (JarvisAudioCore) on the Mac: npm run test:ios.
# `--spm-dir DIR` first keeps SwiftPM's caches and build folder in DIR, for when the usual places aren't writable.
set -e
cd "$(dirname "$0")/../packages/jarvis-audio/ios/JarvisAudioCore"
if [ "$1" = "--spm-dir" ]; then
  dir="$2"; shift 2
  export CLANG_MODULE_CACHE_PATH="$dir/module-cache"
  exec swift test --disable-sandbox --scratch-path "$dir/build" --cache-path "$dir/cache" \
    --config-path "$dir/config" --security-path "$dir/security" "$@"
fi
exec swift test "$@"
