#!/bin/sh
# Checks web-hook/jarvis-mic-sync.patch against the jarvis repo's web app, without touching that repo: copies web/
# into .build/mic-sync-check, applies the patch there, checks that its native.ts matches web-hook/native.ts where
# the two share code (bindNative), then typechecks the web app and runs its tests. JARVIS_REPO defaults to ../jarvis.
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
jarvis="${JARVIS_REPO:-$root/../jarvis}"
work="$root/.build/mic-sync-check"
rm -rf "$work"
mkdir -p "$work/web"
cp -R "$jarvis/web/src" "$jarvis/web/tests" "$jarvis/web/public" "$jarvis/web/tsconfig.json" "$jarvis/web/vite.config.ts" "$jarvis/web/package.json" "$work/web/"
ln -s "$jarvis/web/node_modules" "$work/web/node_modules"
cd "$work"
patch -p1 --silent < "$root/web-hook/jarvis-mic-sync.patch"
bind() { sed -n '/^export function bindNative/,/^}/p' "$1"; }
[ "$(bind web/src/lib/native.ts)" = "$(bind "$root/web-hook/native.ts")" ] || { echo "bindNative in web-hook/native.ts and the patch differ" >&2; exit 1; }
cd web
./node_modules/.bin/tsc --noEmit -p tsconfig.json
./node_modules/.bin/vitest run --config /dev/null
echo "The patch applies to $jarvis/web, typechecks and passes its tests."
