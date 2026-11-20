#!/usr/bin/env bash
# Builds the browser demo.
#
# The MoonBit JS backend writes an ES module and a runtime next to it, so the
# page and the module have to sit in the same directory to resolve the import.
# Everything ends up in web/dist, which is what a static host serves.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$here/.."
dist="$root/web/dist"

moon build --target js --release

rm -rf "$dist"
mkdir -p "$dist"
cp "$root/web/index.html" "$dist/"
# Every file the backend emitted is part of the module: the runtime, the
# package body and the type declarations.
for f in "$root/_build/js/release/build/wasm/"*.js \
         "$root/_build/js/release/build/wasm/"*.d.ts; do
  [ -e "$f" ] || continue
  cp "$f" "$dist/"
done

# The page imports `wasm.js`; the backend names the file after the package, so
# the entry point is renamed to keep the import stable across package renames.
if [ -f "$dist/wasm.js" ]; then
  mv "$dist/wasm.js" "$dist/wasm.js"
fi

echo "demo written to web/dist"
ls -1 "$dist"
