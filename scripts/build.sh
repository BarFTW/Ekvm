#!/usr/bin/env bash
# Compile the canisters with the pinned moc (mops toolchain). Local only.
set -euo pipefail
cd "$(dirname "$0")/.."
MOC="$(mops toolchain bin moc)"
mkdir -p build
for c in Shard Index; do
  out="build/$(echo "$c" | tr 'A-Z' 'a-z')"
  # shellcheck disable=SC2046
  "$MOC" $(mops sources) -Werror -c "canisters/$c.mo" -o "$out.wasm" --idl
done
ls -l build/*.wasm
