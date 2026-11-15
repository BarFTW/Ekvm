# Ekvm v2 benchmark baseline (M3)

**Every number on this page is a PocketIC measurement** (local replica emulation, simulated cycles), not a mainnet measurement. It holds only for the scale stated below. No latency, throughput, or 64-shard / 100 M-record claim is made or extrapolated from it (D7, D8).

- Date: 2026-11-15. Code: branch `v2`, M3 commit (see `git log`).
- Machine: 8-core Intel Xeon VM, 15 GiB RAM. PocketIC server 16.1.0, moc 2.2.1, Node 24.
- Topology: one PocketIC application subnet (13-node fee schedule). Every workload gets its own index canister and shards, created by `Index.createShards` (actor-class instantiation, 5 T simulated cycles per shard).
- Schema: the demo `Item` schema with 3 indexes (`by_price` = `nat64(price)`, `by_category_price` = `(text(category), desc(nat64(price)))`, `by_name` = `text(name)`). The index layout is `IxTree` (the M3 default) unless marked `[btree]`.
- Records: ~1 KB Candid `Item` (950-byte payload), from the seeded generator in `ts/bench/gen.ts` (seed 1).
- Reproduce: `scripts/bench.sh baseline` (about 6 min on this machine). It writes `build/bench-m3-baseline.{json,md}`. `scripts/bench.sh smoke` runs the same suite at toy scale; `ts/integration/harness.test.ts` runs that inside `scripts/test-all.sh`.

## Scale actually run

| Workload | Shards | Records | Measured ops |
|---|---:|---:|---|
| YCSB A–E | 4 | 120,000 (100,000 user records + 10,000 feed records for D + 100 × 100 partition records for E) | 1,000 per workload; load = 120,000 inserts in client batches of 400 (~100 per shard message) |
| IX-1 | 1, 2, 4, 8, 16, 32 | 2,000 per shard (2,000 … 64,000) | 5 queries per mode and step |
| IX-2 | 1 per layout | 20,000 | 1,000 payload-only updates + 1,000 price updates per layout |
| IX-3 | 4 | 20,000 (16 distinct Zipf-distributed prices; 8 Zipf-distributed categories; 200-byte payload) | page through every row of the hottest price and the hottest category |

This is about 0.1% of the D7 dataset, with 4 to 32 shards on one subnet instead of 64 shards on 4 subnets.

## Metrics

- **Write instr/op:** the shard's own `ic0.performance_counter` at the end of `write`, summed over shards and divided by write ops. It excludes reply encoding.
- **Write cycles/op:** the drop in the shards' PocketIC cycle balances over the phase, divided by write ops. It includes ingress induction and execution fees, plus idle burn over the phase's short simulated time. Queries are free.
- **Read instr/call:** the shard's `explain` query re-runs a sampled read (1 in 5 for YCSB, every call for IX) on the same state and returns its instruction counter. Read instr/op = per call × shard read calls per op. For a global query, that is the total over all shards.
- **Msgs/op:** calls from the client to shard canisters per op. Map fetches are excluded; they happen once per client.
- **Rows fetched / returned:** global-query rows received from shards vs rows the client returned (fan-out waste).

## Results

| Workload | S | Records | Ops | Mix | Msgs/op | Write instr/op | Write cycles/op | Read instr/op | Read instr/call | Rows fetched / returned | Notes |
|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---|
| load | 4 | 120,000 | 120000 | insert 100% | 0.01 | 1,047,502 | 4,468,704 | – | – |  | heapBytesPerRecord=4136, maxLiveBytesPerRecord=2628 |
| YCSB-A | 4 | 120,000 | 1000 | read 51%, update 49% | 1 | 4,239,564 | 17,380,071 | 1,073,504 | 2,117,365 |  |  |
| YCSB-B | 4 | 120,000 | 1000 | read 95%, update 5% | 1 | 4,208,246 | 17,314,686 | 2,024,777 | 2,133,590 |  |  |
| YCSB-C | 4 | 120,000 | 1000 | read 100%, update 0% | 1 | – | – | 2,126,599 | 2,126,599 |  |  |
| YCSB-D | 4 | 120,000 | 1000 | read 94%, insert 6% | 1 | 7,375,583 | 23,659,296 | 2,661,912 | 2,822,812 |  |  |
| YCSB-E | 4 | 120,000 | 1000 | scan 96%, insert 4% | 1 | 7,054,148 | 23,016,724 | 3,271,509 | 3,400,737 |  | avgScanRows=34.13 |
| IX-1 topN100 exact | 1 | 2,000 | 5 | topN 100% | 1 | – | – | 28,838,230 | 28,838,230 | 500 / 500 | roundsPerQuery=1 |
| IX-1 topN100 adaptive | 1 | 2,000 | 5 | topN 100% | 1 | – | – | 38,964,394 | 38,964,394 | 1000 / 500 | roundsPerQuery=1 |
| IX-1 range page | 1 | 2,000 | 5 | range 100% | 1 | – | – | 30,522,474 | 30,522,474 | 500 / 500 |  |
| IX-1 topN100 exact | 2 | 4,000 | 5 | topN 100% | 2 | – | – | 59,345,693 | 29,672,847 | 1000 / 500 | roundsPerQuery=1 |
| IX-1 topN100 adaptive | 2 | 4,000 | 5 | topN 100% | 2 | – | – | 59,345,693 | 29,672,847 | 1000 / 500 | roundsPerQuery=1 |
| IX-1 range page | 2 | 4,000 | 5 | range 100% | 2 | – | – | 59,848,526 | 29,924,263 | 1000 / 500 |  |
| IX-1 topN100 exact | 4 | 8,000 | 5 | topN 100% | 4 | – | – | 121,674,145 | 30,418,536 | 2000 / 500 | roundsPerQuery=1 |
| IX-1 topN100 adaptive | 4 | 8,000 | 5 | topN 100% | 4 | – | – | 88,665,816 | 22,166,454 | 1000 / 500 | roundsPerQuery=1 |
| IX-1 range page | 4 | 8,000 | 5 | range 100% | 4 | – | – | 124,628,782 | 31,157,195 | 2000 / 500 |  |
| IX-1 topN100 exact | 8 | 16,000 | 5 | topN 100% | 8 | – | – | 255,031,886 | 31,878,986 | 4000 / 500 | roundsPerQuery=1 |
| IX-1 topN100 adaptive | 8 | 16,000 | 5 | topN 100% | 8 | – | – | 124,120,853 | 15,515,107 | 1000 / 500 | roundsPerQuery=1 |
| IX-1 range page | 8 | 16,000 | 5 | range 100% | 8 | – | – | 257,614,053 | 32,201,757 | 4000 / 500 |  |
| IX-1 topN100 exact | 16 | 32,000 | 5 | topN 100% | 16 | – | – | 532,480,239 | 33,280,015 | 8000 / 500 | roundsPerQuery=1 |
| IX-1 topN100 adaptive | 16 | 32,000 | 5 | topN 100% | 16 | – | – | 179,918,759 | 11,244,922 | 1040 / 500 | roundsPerQuery=1 |
| IX-1 range page | 16 | 32,000 | 5 | range 100% | 16 | – | – | 540,626,855 | 33,789,178 | 8000 / 500 |  |
| IX-1 topN100 exact | 32 | 64,000 | 5 | topN 100% | 32 | – | – | 1,097,881,561 | 34,308,799 | 16000 / 500 | roundsPerQuery=1 |
| IX-1 topN100 adaptive | 32 | 64,000 | 5 | topN 100% | 34 | – | – | 267,314,420 | 7,862,189 | 1190 / 500 | roundsPerQuery=2 |
| IX-1 range page | 32 | 64,000 | 5 | range 100% | 32 | – | – | 1,103,068,756 | 34,470,899 | 16000 / 500 |  |
| IX-2 payload-only update [btree] | 1 | 20,000 | 1000 | update 100% | 1 | 4,045,408 | 16,990,435 | – | – |  | changedIndexKeysPerOp=0 |
| IX-2 price update [btree] | 1 | 20,000 | 1000 | update 100% | 1 | 10,734,306 | 30,367,842 | – | – |  | changedIndexKeysPerOp=2, instrPerChangedKey=3344449, heapBytesPerRecord=8578, maxLiveBytesPerRecord=3282 |
| IX-2 payload-only update [prefix] | 1 | 20,000 | 1000 | update 100% | 1 | 4,044,138 | 16,987,896 | – | – |  | changedIndexKeysPerOp=0 |
| IX-2 price update [prefix] | 1 | 20,000 | 1000 | update 100% | 1 | 8,032,181 | 24,963,272 | – | – |  | changedIndexKeysPerOp=2, instrPerChangedKey=1994022, heapBytesPerRecord=9822, maxLiveBytesPerRecord=3379 |
| IX-3 hottest price value | 4 | 20,000 | 58 | page 100% | 4 | – | – | 25,765,991 | 6,441,498 | 22383 / 5746 | pages=58, matching=5746 |
| IX-3 hottest category (by_category_price) | 4 | 20,000 | 74 | page 100% | 4 | – | – | 57,356,239 | 14,339,060 | 28745 / 7337 | pages=74, matching=7337 |

### Observations (at this scale only)

- **Point reads** cost ~2.1 M instructions per `get` call. Updates that don't change index keys cost ~4.2 M instructions and ~17.4 M cycles per single-op ~1 KB write. Inserts (D, E) maintain 3 new index entries and cost ~7.1–7.4 M instructions and ~23 M cycles.
- **Batched load** (≈100 ops per shard message) costs ~1.05 M instructions and ~4.5 M cycles per record. The §5.7 estimate of ~5.3 M cycles per batched write was in the same range; this page does not re-derive the estimate.
- **Memory:** after the load, the largest live heap at the end of a GC (`rts_max_live_size`) is ~2.6 KB per ~1 KB record, with 3 indexes. The current heap including uncollected garbage is ~4.1 KB per record. These are upper bounds on live data, at 30,000 records per shard.
- **Partition scans** (YCSB-E, avg 34 rows) cost ~3.4 M instructions per call.
- **`ixScan` pages are expensive:** a 100-row page costs ~29–34 M instructions per shard, about 0.3 M per row. It is probably dominated by the primary-record lookup per row (§5.8), which touches cold pages. That breakdown is not measured. That is under the §5.7 per-row bound (~0.5 M), but not by much.
- **IX-1 fan-out:**
  - Exact mode asks every shard for `limit` rows. Rows fetched are S × 100, and total read instructions grow linearly with S, from 29 M at S = 1 to 1.1 B at S = 32.
  - Adaptive mode (⌈2·limit/S⌉ per shard) fetches 1,000–1,190 rows for 500 returned and costs 267 M instructions at S = 32, about 4× less than exact.
  - Adaptive took one round up to S = 16. At S = 32, each query needed a second round for 2 shards (34 calls per query instead of 32).
  - At S = 1, adaptive asks for 200 rows and costs more than exact.
- **IX-3 (ties):** all 5,746 rows tied on the hottest price came back over 58 pages, and all 7,337 rows of the hottest category over 74 pages. Both runs were in exact global order with no duplicates or gaps. Rows fetched were ~3.9× rows returned (4 shards, exact mode).
- **Shard creation (PocketIC fee schedule):** the observed fee was 502.1 B cycles per shard (attached cycles minus starting balance). That is the 500 B creation fee plus install.

## D11 index-tree locality experiment

**Question (§14 Q1 / D11):** does a more memory-local index tree lower the instructions per *changed* index key? Per M1, most of that cost is the IC per-page memory charge.

**Variants:**
- **Before: `#btree`.** The M1/M2 index: `core` `Map<IxPos, ()>`, a B-tree of order 32. Every key comparison dereferences a tuple, an `IxPos` record and its blobs, which sit at scattered heap addresses.
- **After: `#prefix`, `src/IxTree.mo`.** A B+tree of order 64 whose nodes keep, beside the keys, two parallel arrays of unboxed scalars. Each scalar holds 7 bytes of an order-preserving byte stream of `(ixKey, pk, sk)`, so the first 14 bytes are inline. Binary search compares scalars inside the node's own arrays and dereferences the full key only on a 14-byte tie. Leaves are linked for range scans.

Both layouts run the same `Store` code. A shard picks its layout at install (`ixLayout` init field).

### D11 method (`ts/integration/bench.test.ts`)

- Single-op writes of ~1 KB records on one shard preloaded with 20,000 records.
- The shard is built with 0, 1, 2 and 3 indexes. Instructions per index key are the least-squares slope over k = 0…3.
- Each phase touches the N most recently inserted keys.
- The table below is from N = 1,000 ops per phase. A run with N = 200 agreed within ~10%.

| Phase (per op) | `#btree` instr per index key | `#prefix` instr per index key | Change |
|---|---:|---:|---:|
| insert (adds k index keys) | 1,603,192 | 1,021,512 | −36% |
| update changing every index key (k removes + k adds) | 1,863,531 | 1,329,080 | −29% |
| delete (removes k index keys) | 1,553,572 | 1,034,380 | −33% |
| update with unchanged index keys | 59,225 (≈ +0–2% per index) | 235,260 (≈ +5–8% per index) | worse |
| batched insert, 100 per message | 128,441 | 153,494 | +20% (worse) |

### Random keys over the whole shard (IX-2 in the harness)

- 20,000 records, 1,000 updates on Zipf-scrambled keys.
- Each price update changes 2 index keys (`by_price`, `by_category_price`). The baseline is the same updates with only the payload changed.

| | `#btree` | `#prefix` | Change |
|---|---:|---:|---:|
| Payload-only update, instr/op | 4,045,408 | 4,044,138 | 0% |
| Price update, instr/op | 10,734,306 | 8,032,181 | −25% |
| **Instructions per changed index key** | **3,344,449** | **1,994,022** | **−40%** |
| Price update, cycles/op | 30.4 M | 25.0 M | −18% |
| Max live heap per record (after the run) | 3,282 B | 3,379 B | +3% |

### Result

- `IxTree` cuts the per-changed-key cost by 29–40% for single-op writes in every measurement. It is the default layout from M3 on.
- It is worse in two places:
  - batched inserts: about +20% per index key;
  - single-op writes whose index keys don't change: about +5–8% per index instead of ~0–2%. That is still inside D11's ≤ 10%.
- Memory is about the same.

**The D11 budget was not lowered.** The experiment wins clearly in relative terms, and under D11's own method `#prefix` measures at most 1.33 M per changed key, under the 1.5 M budget. But the more realistic IX-2 measurement, with random keys over the whole shard, gives 2.0 M per changed key even with `IxTree` (3.3 M with the old tree). The D11 method touches recently inserted, memory-local keys, and so understates the cost. Lowering the figure would state a budget that only holds under the favourable method. See DESIGN.md §14 Q3.

## Not measured here

- Wall-clock latency (PocketIC is not the IC network; D8).
- Per-shard and per-subnet ops/s ceilings. Deriving them needs per-round instruction and thread limits, which are not verified yet.
- Multiple subnets (M5).
- The D7 scale and the 16/32/64 ladder at D7 per-shard size.
