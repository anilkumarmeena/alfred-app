#!/bin/sh
# Checks web-hook/jarvis-preferences.patch against the jarvis repo, without touching that repo: copies its Python
# package, tests, docs and web app into .build/preferences-check, applies the patch there, then typechecks the web
# app, runs its tests, and runs the panel's Python tests with the jarvis project's environment.
# JARVIS_REPO defaults to ../jarvis.
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
jarvis="${JARVIS_REPO:-$root/../jarvis}"
work="$root/.build/preferences-check"
rm -rf "$work"
mkdir -p "$work/web"
rsync -a --exclude __pycache__ "$jarvis/jarvis" "$jarvis/tests" "$jarvis/docs" "$jarvis/README.md" "$jarvis/pyproject.toml" "$work/"
ln -s "$jarvis/models" "$work/models"  # the Kokoro voices, which the preference tests list
cp -R "$jarvis/web/src" "$jarvis/web/tests" "$jarvis/web/public" "$jarvis/web/tsconfig.json" "$jarvis/web/vite.config.ts" "$jarvis/web/package.json" "$work/web/"
ln -s "$jarvis/web/node_modules" "$work/web/node_modules"
cd "$work"
patch -p1 --silent < "$root/web-hook/jarvis-preferences.patch"
(cd web && ./node_modules/.bin/tsc --noEmit -p tsconfig.json && ./node_modules/.bin/vitest run --config /dev/null)
uv run --project "$jarvis" --with pytest python -m pytest -q -p no:cacheprovider tests/test_panel.py
echo "The patch applies to $jarvis, typechecks and passes its tests."
