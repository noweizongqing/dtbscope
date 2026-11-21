#!/usr/bin/env bash
# Regenerates the checked-in device tree fixtures from their sources.
#
# Fixtures are compiled once and committed so that `moon test` runs without
# dtc. This script exists so that the committed bytes can be reproduced: CI
# runs it with --check and fails if the result differs from what is in the
# tree, which catches a fixture edited by hand or a dtc version change.
#
# Three kinds of source are handled, told apart by what the file contains
# rather than by its name, so that renaming one does not silently change how it
# is compiled:
#
#   /plugin/   a source of patches; needs -@ so its own labels are exported and
#              its output is named .dtbo
#   labels     a base tree something overlays onto; needs -@ so __symbols__
#              exists, or no overlay can resolve against it
#   plain      everything else; no -@, because adding it writes a __symbols__
#              node dtc would not otherwise emit and the comparison fails

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixtures="$here/../internal/fixtures"
mode="${1:-write}"

if ! command -v dtc >/dev/null 2>&1; then
  echo "dtc not found. Install it with: brew install dtc" >&2
  exit 1
fi

# Files that need -@ but are not plugins: their labels have to be exported for
# an overlay to refer to them.
base_trees="overlay-base overlay-labels"

compiled=0
failed=0

for src in "$fixtures"/*.dts "$fixtures"/*.pre.dts; do
  [ -e "$src" ] || continue
  # `.expected.dts` files are dtc's own output, checked in so the emitter test
  # can compare against it. Compiling them would produce a fixture nothing
  # reads.
  case "$src" in *.expected.dts) continue ;; esac
  base="${src%.pre.dts}"
  base="${base%.dts}"
  stem="$(basename "$base")"

  flags=()
  ext="dtb"
  if grep -q '^[[:space:]]*/plugin/' "$src"; then
    flags+=("-@")
    ext="dtbo"
  elif printf '%s\n' $base_trees | grep -qx "$stem"; then
    flags+=("-@")
  fi

  out="$base.$ext"
  tmp="$(mktemp)"
  # An empty array expands to nothing under `set -u` only with this guard, so
  # the two cases are written out rather than relying on `"${flags[@]}"`.
  if [ ${#flags[@]} -eq 0 ]; then
    ok=0
    dtc -q -I dts -O dtb -o "$tmp" "$src" 2>/dev/null || ok=1
  else
    ok=0
    dtc -q "${flags[@]}" -I dts -O dtb -o "$tmp" "$src" 2>/dev/null || ok=1
  fi
  if [ "$ok" -ne 0 ]; then
    echo "dtc rejected $src" >&2
    failed=1
    rm -f "$tmp"
    continue
  fi
  compiled=$((compiled + 1))
  if [ "$mode" = "--check" ]; then
    if ! cmp -s "$tmp" "$out"; then
      echo "fixture out of date: $out" >&2
      echo "run tools/gen-fixtures.sh to regenerate" >&2
      failed=1
    fi
  else
    mv "$tmp" "$out"
  fi
  rm -f "$tmp"
done

echo "dtc $(dtc --version | sed 's/Version: //') compiled $compiled fixture(s)"
exit "$failed"