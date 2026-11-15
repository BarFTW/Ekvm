#!/usr/bin/env bash
# Compile the canisters with the pinned moc (mops toolchain). Local only.
set -euo pipefail
cd "$(dirname "$0")/.."
MOC="$(mops toolchain bin moc)"
mkdir -p build
# build NAME CANISTER [SCHEMA_DIR]: the shard schema is the moc package `ekvm-schema`.
build() {
  local name="$1" src="$2" schema="${3:-schemas/empty}"
  # shellcheck disable=SC2046
  "$MOC" $(mops sources) --package ekvm-schema "$schema" -Werror -c "canisters/$src.mo" -o "build/$name.wasm" --idl
}
build index Index
build shard Shard
# Test/bench shards with 0..3 demo indexes (ix3 is the demo schema).
for k in 0 1 2 3; do build "shard-ix$k" Shard "test/schemas/ix$k"; done
ls -l build/*.wasm
