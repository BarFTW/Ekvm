#!/usr/bin/env bash
# Full local test run: vectors in sync, Motoko unit tests, TS unit tests,
# TS typecheck, PocketIC integration (multi-subnet). Never touches a real network.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 tools/gen_vectors.py --check
mops test
scripts/build.sh
(cd ts && npx tsc --noEmit -p . && node --test test/*.test.ts)
(cd ts && POCKET_IC_BIN="$(cd .. && mops toolchain bin pocket-ic)" node --test --test-concurrency=1 integration/*.test.ts)
