#!/usr/bin/env bash
# Benchmark suite on a local PocketIC server (DESIGN.md §12). Local only:
# no network, simulated cycles. Usage: scripts/bench.sh [smoke|baseline]
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build.sh >/dev/null
cd ts && POCKET_IC_BIN="$(cd .. && mops toolchain bin pocket-ic)" node bench/run.ts "${1:-smoke}"
