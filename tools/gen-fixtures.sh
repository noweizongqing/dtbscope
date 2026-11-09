#!/usr/bin/env bash
# Regenerates the checked-in DTB fixtures from their DTS sources.
#
# Fixtures are compiled once and committed so that `moon test` runs without
# dtc. This script exists so that the committed bytes can be reproduced: CI
# runs it with --check and fails if the result differs from what is in the
# tree, which catches a fixture edited by hand or a dtc version change.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixtures="$here/../internal/fixtures"
mode="${1:-write}"

if ! command -v dtc >/dev/null 2>&1; then
  echo "dtc not found. Install it with: brew install dtc" >&2
  exit 1
fi

compiled=0
failed=0

for src in "$fixtures"/*.dts; do
  [ -e "$src" ] || continue
  out="${src%.dts}.dtb"
  tmp="$(mktemp)"
  # -I dts -O dtb is the only direction needed for fixtures: the DTS sources
  # are the readable form and the DTB is what the tests parse.
  if ! dtc -q -I dts -O dtb -o "$tmp" "$src" 2>/dev/null; then
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