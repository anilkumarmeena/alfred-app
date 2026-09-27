#!/bin/sh
# Checks server-hook/jarvis-native-push.patch against the jarvis repo, without touching that repo: copies its
# Python package, tests and web/src/state/push.ts into .build/server-patch-apply, applies the patch there, then
# runs the jarvis tests on the copy with the jarvis project's environment (as `make test` does, plus h2).
# JARVIS_REPO defaults to ../jarvis. `--no-test` only applies the patch.
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
jarvis="${JARVIS_REPO:-$root/../jarvis}"
work="$root/.build/server-patch-apply"
rm -rf "$work"
mkdir -p "$work/web/src/state"
rsync -a --exclude __pycache__ "$jarvis/jarvis" "$jarvis/tests" "$jarvis/pyproject.toml" "$work/"
cp "$jarvis/web/src/state/push.ts" "$work/web/src/state/"
[ -d "$jarvis/web/dist" ] && ln -s "$jarvis/web/dist" "$work/web/dist"
cd "$work"
patch -p1 --silent < "$root/server-hook/jarvis-native-push.patch"
echo "The patch applies to $jarvis."
[ "$1" = "--no-test" ] && exit 0
uv run --project "$jarvis" --with pytest --with h2 python -m pytest -q -p no:cacheprovider
