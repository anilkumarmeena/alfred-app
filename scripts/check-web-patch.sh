#!/bin/sh
# Checks web-hook/jarvis-web.patch against the jarvis repo's current web app, without touching that repo: copies
# web/ into .build/web-patch-check, applies the patch there, then typechecks and runs the web app's own tests.
# JARVIS_REPO defaults to ../jarvis. Run it after pulling changes to the web page, before applying the patch.
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
jarvis="${JARVIS_REPO:-$root/../jarvis}"
work="$root/.build/web-patch-check"
rm -rf "$work"
mkdir -p "$work/web"
cp -R "$jarvis/web/src" "$jarvis/web/tests" "$jarvis/web/public" "$jarvis/web/tsconfig.json" "$jarvis/web/vite.config.ts" "$jarvis/web/package.json" "$work/web/"
ln -s "$jarvis/web/node_modules" "$work/web/node_modules"
cd "$work"
patch -p1 --silent < "$root/web-hook/jarvis-web.patch"
cmp -s web/src/lib/native.ts "$root/web-hook/native.ts" || { echo "web-hook/native.ts and the patch differ: regenerate the patch" >&2; exit 1; }
cd web
./node_modules/.bin/tsc --noEmit -p tsconfig.json
./node_modules/.bin/vitest run --config /dev/null
echo "The patch applies to $jarvis/web, typechecks and passes its tests."
