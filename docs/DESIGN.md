# Ekvm v2: Design

Status: design complete (D1–D9) · rev 3 · 2026-11-13 · License: Apache-2.0 (same as v1)

Ekvm ("Elastic Key-Value Map") is a **general-purpose** Motoko database library for the Internet Computer: a key-value store spread across many canisters, with user-defined secondary indexes and global ordered scans. This document covers a rewrite. The v1 code (`BarFTW/Ekvm`, 2024) is a reference for the idea only. No v1 code is reused.

Facts marked **[unverified]** were not confirmed in official docs while this was written. They must be checked before we depend on them. Numbers marked **[proposed target]** are design goals pending measurement, not measurements.

---

## 0. Decisions log

| # | Decision | Date |
|---|---|---|
| D1 | Global ordered scans across all shards are a requirement, over **user-defined secondary indexes** (any field or composite). Approach: §5 | 2026-11-13 |
| D2 | Uncertified (single-replica) query reads are acceptable. A certified read path is **out of v1 scope** (§10) | 2026-11-13 |
| D3 | Ekvm v2 is a generic library, not tied to any application. Validated by a synthetic benchmark suite (YCSB-like mixes, range and index scans), with ad auctions as at most one example workload (§12) | 2026-11-13 |
| D4 | Secondary indexes are declared in Motoko code (`Schema` compiled into the shard wasm). Adding an index = rolling shard upgrade + backfill (§3, §4.4). Runtime-declared indexes are out of scope | 2026-11-13 |
| D5 | Read-committed global scans are acceptable for v1: an entry whose index value changes between pages may appear twice or be skipped (§5.6). Snapshot scans are out of scope | 2026-11-13 |
| D6 | Performance targets as in §5.7, **proposed targets pending measurement**. The 64-shard global-page p95 is the M6 go/no-go threshold for the global index tier | 2026-11-13 |
| D7 | Benchmark uses YCSB-standard ~1 KB records: 100 M records, 3 secondary indexes, on **~50+ shards** (planned: 64) across multiple subnets (§5.7, §12). Supersedes D6's 16-shard benchmark scale | 2026-11-13 |
| D8 | No mainnet runs for now: all benchmarks run on PocketIC. The mainnet cost estimates in §5.7 are kept as reference only | 2026-11-13 |
| D9 | 32-shard ladder target confirmed: global top-100 page p50 < 600 ms, p95 < 1.2 s | 2026-11-13 |

---

## 1. Why a rewrite, and what changed since 2024

v1 was built because a single canister couldn't hold a meaningful database. That reason has mostly gone away:

| Limit (today) | Value | Source |
|---|---|---|
| Stable memory per canister | 500 GiB | [Resource limits][limits] |
| Wasm heap per canister | 4 GiB (wasm32), 6 GiB (wasm64) | [Resource limits][limits] |
| Subnet total memory | 2 TiB, shared by all canisters on the subnet | [Resource limits][limits] |
| Update execution threads | 1 per canister, 4 per subnet | [Resource limits][limits] |
| Query execution threads | 2 per canister, 4 per replica node | [Resource limits][limits] |
| Instructions | 40 B per update, 5 B per query | [Resource limits][limits] |
| Payload | 2 MiB ingress, 2 MiB cross-subnet, 10 MiB same-subnet request; 3 MiB query response | [Resource limits][limits] |
| Block rate | 1–3 blocks/s, up to 1,000 messages per block | [Resource limits][limits] |
| Latency | update ~1–2 s, query ~200 ms | [Canisters][canisters], [Inter-canister calls][icc] |

Motoko now uses **enhanced orthogonal persistence (EOP)** by default (since moc 0.15.0). A `persistent actor` keeps its 64-bit heap across upgrades without serializing it, and upgrade time no longer grows with heap size ([EOP][eop], [overview][op]).

**The real problem is throughput, not size.** One canister can hold many GB, but:

- **Writes.** A canister executes one update at a time, and a subnet has only 4 update threads. Write throughput therefore scales only by spreading shards over **multiple subnets**.
- **Reads.** Queries are cheap and parallel, but each canister gets at most 2 query threads per node, so a hot read set has to be spread across canisters too.
- **Storage headroom.** 500 GiB per canister is a ceiling, not a promise, because all canisters on a subnet share 2 TiB. Above 750 GiB of subnet usage, storage reservation fees start ([cycle costs][cycles]).

Unbounded size comes for free once the design scales out.

### v1 problems this design removes

| v1 issue | v2 answer |
|---|---|
| Index canister on every `get`/`put` (two to three hops) | Clients route directly to shards using a cached shard map (§4) |
| `put` and `addKeyToShard` callable by anyone | Allowlist checked inside each shard; admin restricted to controllers (§7) |
| Heap BTree described as "stable memory"; `stableVarQuery` used as a memory check | EOP heap, stated plainly; memory measured with `canister_status`/runtime stats (§6) |
| Shard growth never wired up | Explicit split/move protocol driven by the index (§4.3) |
| 15 B cycles attached to every call | No cycles on data calls. Cycles move only for creation and top-ups (§8) |
| No top-up, no child upgrades | Index runs top-up and rolling upgrades (§8, §9) |
| No delete; overwrite left a stale location | No per-key location directory. Location is a pure function of the key, so delete and overwrite are local (§4) |

### Prior art

- **CanDB** (canscale → [ORIGYN-SA/CanDB][candb]) uses a partition-key/sort-key model with a canister per partition. Its repo was last pushed 2024-03-20, so treat it as dormant. Ekvm v2 borrows the PK/SK idea and adds client-side routing, rebalancing and secondary indexes.
- **`mo:core/Map`** ([motoko-core][core], v2.7.0) is a B-tree of order 32 that is stable under EOP. It is derived from the same StableHeapBTreeMap that v1 used, and it is our in-shard storage and index structure.
- Design borrowings from outside the IC: Redis Cluster (hash slots), DynamoDB (local vs global secondary indexes, async GSI propagation), YCSB (benchmark workloads).

---

## 2. Goals / non-goals

**Goals**
1. Horizontal write and read throughput: add shards, including on other subnets, without downtime.
2. One network hop per point operation. The index canister is never consulted per request.
3. Per-key linearizable writes, optimistic concurrency (version / CAS), and idempotent retries.
4. Ordered range scans within a partition key (single shard).
5. **User-defined secondary indexes** over any field or composite of fields, with **global ordered scans** (range, top-N, pagination) across all shards (D1).
6. Operable by one person: automatic cycle top-ups, rolling upgrades with snapshots, metrics.
7. A Motoko library (mops package) plus a TypeScript client. Application-agnostic (D3).

**Non-goals (v1 of the rewrite)**
- Cross-shard transactions.
- Globally unique secondary indexes (uniqueness can only be enforced per shard).
- Snapshot-isolated global scans (§5.6, D5).
- Runtime-declared secondary indexes (D4).
- Certified (subnet-signed) query responses (D2, §10).
- A query language, joins, or aggregation beyond ordered scans.
- Mainnet deployment or cycle purchasing tooling.

---

## 3. Data model and API

**Primary key** = `(pk : Blob, sk : Blob)`.
- `pk` (partition key) decides placement.
- `sk` (sort key) orders entries within a partition.

**Value** = `Blob`, at most 1 MiB, so a batch still fits under the 2 MiB message limit. Each entry also carries:
- a `version : Nat64`, a per-shard monotonically increasing write counter;
- an optional `ttl`;
- the entry's current secondary index keys, used to remove stale index entries on overwrite or delete (§5.2).

### Secondary indexes

An index is declared in code in a `Schema` module that the library user compiles into their shard wasm:

```motoko
type IndexDef = {
  id : Nat16; name : Text;
  extract : (pk : Blob, sk : Blob, value : Blob) -> ?Blob;  // null = not indexed
};
```

`extract` returns an **order-preserving encoded** index key. The library ships encoders for both Motoko and TS, with shared test vectors:
- `Nat`/`Int` as fixed-width big-endian, with a sign-bit flip for signed values;
- `Float` (IEEE-754 bit trick);
- `Text` (UTF-8 with escaping and a terminator, so prefixes sort correctly);
- `desc(x)` (bitwise complement);
- tuples (concatenation of self-delimiting parts).

The physical index key is always `ixKey ‖ pk ‖ sk`. This makes the order total, so there are no ties even when many entries share a value, and it gives a stable tiebreaker.

**Why shard-side extraction instead of client-supplied index keys:**
- Writers can't produce inconsistent index keys.
- A new index can be backfilled from existing values.
- The cost is that adding or changing an index requires a shard upgrade plus a backfill job (§4.4). Accepted (D4).

### Shard API (Candid; the client library wraps it)

```motoko
type Key     = { pk : Blob; sk : Blob };
type Entry   = { key : Key; value : Blob; version : Nat64 };
type Cond    = { #any; #absent; #version : Nat64 };          // CAS
type WriteOp = { #put : { key : Key; value : Blob; cond : Cond }
               ; #delete : { key : Key; cond : Cond } };
type Err     = { #wrongShard : { epoch : Nat64 }              // client must refresh map
               ; #conflict : { key : Key; current : ?Nat64 }
               ; #unauthorized; #tooLarge; #migrating; #unknownIndex };
type Bound   = { #incl : Blob; #excl : Blob; #unbounded };
type IxRow   = { ixKey : Blob; key : Key; version : Nat64; value : ?Blob };

// updates
write   : (req : { epoch : Nat64; requestId : Blob; ops : [WriteOp] })
            -> async Result<[Nat64], Err>;   // all-or-nothing within one shard, incl. local indexes
// queries
get     : query ({ epoch : Nat64; keys : [Key] }) -> async Result<[?Entry], Err>;
scan    : query ({ epoch : Nat64; pk : Blob; from : Bound; to : Bound;
                   limit : Nat; reverse : Bool }) -> async Result<{ entries : [Entry]; next : ?Blob }, Err>;
ixScan  : query ({ epoch : Nat64; index : Nat16; from : Bound; to : Bound; after : ?Blob;
                   limit : Nat; reverse : Bool; withValues : Bool })
            -> async Result<{ rows : [IxRow]; more : Bool }, Err>;   // this shard's slice, in order
```

- A batch `write` to one shard executes as a single message, so it is atomic, including the shard's local index updates.
- The client library splits a multi-key batch by shard and sends the parts in parallel. Across shards there is **no** atomicity (§10).
- `scan` and `ixScan` are paginated by an instruction budget as well as `limit`, so they stay under the 5 B query instruction limit and the 3 MiB response limit.

### Client API (TS and Motoko)

```ts
put / get / delete / batch(ops)
scan(pk, range, opts)                       // single shard
query(index, range, { limit, reverse, cursor, withValues })   // global ordered scan, §5
  → { rows, cursor | null }
topN(index, n, { reverse }) = query(index, unbounded, { limit: n, ... })
```

### Index-canister API

```motoko
shardMap   : query () -> async { epoch : Nat64; slots : [(Nat16, Nat16, Principal)]; schemaVersion : Nat };
// admin, controllers only:
addWriter / removeWriter / setReaders;  addShard(subnet : ?Principal);  moveSlots(range, to);
uploadShardWasm(chunk) / commitShardWasm(sha256);  upgradeShards(plan);  backfillIndex(id);  status()
```

---

## 4. Architecture

```mermaid
flowchart LR
  subgraph Client["Client (TS lib / Motoko lib)"]
    C[cached shard map<br/>epoch N<br/>k-way merge]
  end
  subgraph SubnetA["Subnet A"]
    I[Index canister<br/>slot map · wasm · cycles · admin]
    S1[Shard 1<br/>slots 0..21844<br/>primary + local indexes]
    S2[Shard 2<br/>slots 21845..43689]
  end
  subgraph SubnetB["Subnet B"]
    S3[Shard 3<br/>slots 43690..65535]
  end
  C -- "shardMap (query, on start / on #wrongShard)" --> I
  C -- "get/scan/ixScan (query) · write (update)" --> S1
  C --> S2
  C --> S3
  I -. "assign slots · top-up · upgrade · backfill · status" .-> S1
  I -.-> S2
  I -.-> S3
```

### 4.1 Partitioning: fixed hash slots, not a ring

- `slot = hash(pk) mod 65536`, using SHA-256 truncated to 16 bits so the hash is stable across languages.
- The slot map assigns contiguous slot ranges to shards. This is the Redis Cluster model.
- **Why slots and not a consistent-hash ring:** moving one slot range is an explicit, bounded unit of migration. The map is small (ranges, typically under 1 KB). Ownership is easy to verify on the shard side.
- **Why hash for the primary key:** it spreads load evenly regardless of how keys are distributed. Orders other than "within one `pk`" are served by secondary indexes (§5).
- **Hot partition caveat:** a single `pk` can't be split. If one partition could exceed one shard's write rate, the application has to spread it itself, e.g. `pk = id # bucket`.

### 4.2 Client-side routing

- The client fetches `shardMap` once with a query and caches it with its `epoch`. It then calls shards directly.
- Every request carries the client's `epoch`.
- Each shard holds its own copy of the ranges it owns, pushed by the index. It answers `#wrongShard { epoch }` when it doesn't own the slot. The client then refreshes the map and retries once.
- The index is never on the hot path. If the index is down, data traffic continues.
- Composite queries are **same-subnet and ingress-only** ([Canisters][canisters]). They therefore can't be the general fan-out mechanism. Cross-shard reads are fanned out by the client in parallel (§5.4).

### 4.3 Split / move protocol

The index runs the protocol. Each step is persisted before every `await`, so a crash or trap resumes from a timer.

1. **Trigger.** A shard exceeds a configured write rate or memory threshold (default: heap > 2 GiB), or the operator calls `moveSlots`. The index creates the target shard if needed.
2. **Copy.** The source shard marks range R as `migrating → T` and starts a per-range change log. The index pulls snapshot pages from the source and pushes them to T with batched `write` calls. During this phase the source still serves reads and writes for R. T rebuilds local index entries as it ingests, using the same `extract`.
3. **Catch-up.** The index replays the change log to T, repeating until the log is small.
4. **Cutover.** The source freezes writes on R (writes get `#migrating` and the client retries with backoff). The index drains the final log, then:
   - T becomes owner of R.
   - The source drops ownership of R.
   - The index bumps `epoch`.

   The freeze lasts roughly 2–3 update rounds.
5. **Cleanup.** The source deletes R's data and its local index entries in background batches, using a timer and staying within the instruction budget.

Merging two shards is the same protocol run in reverse. Shard deletion is manual for now.

During a move, a global scan may see R on both shards. The source keeps serving R until cutover and filters out slots it no longer owns after it. `ixScan` rows from a shard are therefore restricted to slots that shard currently owns, so a page never double-counts.

### 4.4 Adding or changing an index

1. Deploy a shard wasm whose `Schema` adds index `id` in state `#building` (§9).
2. The index canister runs `backfillIndex(id)`: each shard walks its primary map in instruction-bounded batches on a timer and builds the entries.
3. New writes maintain the index immediately.
4. When every shard reports done, the index flips the index to `#ready`. Until then, `query` on the index returns `#unknownIndex`, or `#building` with an explicit opt-in.

Dropping an index is the same process run in reverse.

---

## 5. Global ordered scans over secondary indexes (D1)

**Requirement:** for any declared index, return entries across **all** shards in index order:
- in a range or from the top (top-N);
- paged with a cursor;
- at query latency.

### 5.1 Options

**(a) Global secondary index (GSI) shards, range-partitioned.** Separate canisters own contiguous ranges of `ixKey ‖ pk ‖ sk`. Primary shards propagate index changes to them.
- Reads: a top-N or range page touches one or two GSI shards. Latency is about one query, independent of the number of primary shards S.
- Writes: each change to an index key costs, in addition to the primary write:
  - an outbox entry;
  - a delete on the old key's GSI shard;
  - an insert on the new key's GSI shard.

  The old and new keys may sit on different shards. That is 1–2 extra inter-canister update calls per changed index per write, plus execution on both sides (260 K cycles per call plus per byte and instructions [cycles]).
- Consistency: asynchronous, because a single message can't span canisters. The index lags the primary, and while a key changes the GSI can briefly show the entry twice or not at all.
- Ops: a second partitioning scheme with range split/merge, plus hot-range handling. Monotonic keys (timestamps) or a popular top range concentrate writes on one GSI shard. Range splits can cut inside a run of equal values because the key includes `pk ‖ sk`, but a write hot spot on the newest range still moves along with the data.
- Requires a durable outbox, idempotent apply with per-source sequence numbers, repair and rebuild tooling, and cycles for every propagation.

**(b) Local indexes plus scatter-gather k-way merge.** Every primary shard keeps a local B-tree per index, updated in the same message as the primary write. A global scan queries every shard's `ixScan` in parallel and merges the ordered streams on the client.
- Reads: S parallel queries per page. Latency is about the slowest of S queries plus merge time. Read work grows with S: up to S×N rows are fetched to return N.
- Writes: zero amplification across canisters. The index update is a local B-tree delete+insert inside the same atomic message.
- Consistency: each shard's slice is exactly consistent with its primary data. Across shards, the scan is not a snapshot (§5.6), the same as any other cross-shard read.
- Ops: nothing new. Index entries move with their primary rows during splits.

**(c) Hybrid.** Local indexes everywhere (b) as the default and source of truth. An index can opt in to a GSI tier (a) that is fed asynchronously from the shards' local change logs. Queries use the GSI when the index has one and its lag is under a bound, and fall back to scatter-gather otherwise.

### 5.2 Recommendation: (c), staged. Ship (b) first and design (a) as an opt-in tier gated on measurements

- **(b) is correct by construction and cheap for writes,** and on the IC read fan-out is cheaper than write fan-out:
  - Queries cost no cycles and run on any of the subnet's replicas.
  - Updates are the scarce resource: 4 threads per subnet, ~1–2 s, and they cost cycles.
  - A GSI turns every index change into 1–2 extra updates on other canisters, competing for exactly that resource.
- **(b) degrades with S.** Every page touches every shard, so tail latency is the slowest of S, and read cost scales with S×N. Somewhere between "tens" and "hundreds" of shards this stops meeting targets. **The crossover point is unknown and is the main thing the M3/M5 benchmarks must establish.**
- **So:** v1 implements (b) for every index. The API and cursor format are designed so that (a) can be added per index later (`IndexDef.global = true`) without changing client code. Implementing (a) is a decision gate at M6, based on numbers.
- **Unknowns, stated plainly:**
  - the real per-query latency distribution on mainnet, especially p99 with fan-out;
  - boundary-node and HTTP gateway rate limits for many parallel queries from one client **[unverified]**;
  - how large S gets for realistic datasets, given that throughput, not size, drives splitting.

Overwrites in (b):
- The shard stores each entry's current index keys.
- On `put`, it diffs old and new keys and does `delete(old) + insert(new)` in the local index, in the same message.
- On `delete`, it removes all of the entry's index keys.

As a result, index entries can never go stale.

### 5.3 Merge algorithm and pagination cursor

**One page of N rows:**
- The client sends `ixScan(index, range, after = cursor.after, limit = N)` to every shard.
- Each shard returns up to N rows in order, plus `more`.
- The client k-way merges the streams with a heap and returns the first N rows.
- The cursor is the last returned physical key.

This is exact, because the global order is total and each shard resumes strictly after the same key.

**Adaptive mode (optional, M3 decides the default):**
- Ask each shard for `ceil(c·N/S)` rows, with c ≈ 2.
- Any shard whose last row still sorts before the N-th merged row and which reported `more` gets a second round.
- This cuts read work by about S/c at the cost of an occasional second round-trip.

**Cursor (opaque to callers; Candid-encoded and base64 in TS):**

```motoko
type Cursor = {
  v : Nat8;                 // format version
  index : Nat16; schemaVersion : Nat;
  from : Bound; to : Bound; reverse : Bool;
  after : Blob;             // last returned ixKey ‖ pk ‖ sk
  epoch : Nat64;            // hint only; a stale epoch just refreshes the map
};
```

The cursor is **stateless**: no server-side session. It survives shard splits and moves, because it names a position in key space, not a shard. It is also valid unchanged against a future GSI tier.

### 5.4 Fan-out on the IC

- **Client-side parallel queries** are the general mechanism.
  - The TS client issues S concurrent `query` calls.
  - The Motoko client, used from another canister, can only make these as inter-canister calls. From an update that costs cycles and update latency. From a composite query it is limited to the same subnet. Canister callers that need global scans should therefore expect update latency (~1–2 s) unless the shards are co-located.
- **Optional per-subnet gather** (M5):
  - Each subnet gets a small stateless "gather" canister exposing a **composite query** that fans out to the shards on its own subnet and merges them.
  - The client then contacts one gather canister per subnet instead of S shards.
  - Limits:
    - same-subnet only;
    - callable only by external clients;
    - total instructions are bounded across the whole composite evaluation (`MAX_CYCLES_PER_QUERY`);
    - there are also maximum call-depth and wall-clock limits, whose values are **[unverified]** ([IC spec][spec]);
    - a shard migrated to another subnet breaks the gather until the map is refreshed.
- **Page size cap:** `N ≤ 1,000` rows, and `withValues` responses are capped by bytes, since a query response is at most 3 MiB.

### 5.5 Skew and hot spots

- **Many entries with the same index value** (e.g. a popular category or status) aren't a correctness issue, because the `pk ‖ sk` suffix makes the order total. In (b) placement follows the primary hash, so equal values spread across shards automatically.
- **Top-of-range read hot spots** in (b) are spread over all shards' query threads. In (a) they would hit one GSI shard, whose 2 query threads per node become the limit and would need read replicas. This is a further point in favour of (b) first.
- **Low-selectivity indexes** (few distinct values) make range scans long, but `limit` and the instruction budget bound each page.

### 5.6 Scan semantics

- A global scan reads each shard at a different moment, from a single replica (D2).
- An entry whose index key changes between pages can be seen twice or skipped, the usual "read committed" pagination behaviour.
- Within one shard's slice, rows are exactly consistent with that shard's primary data at the time of the query.
- Snapshot scans would need multi-version storage (keeping old versions until a scan's timestamp expires) and are a non-goal. Read-committed behaviour is accepted for v1 (D5).

### 5.7 Performance targets (D6, proposed targets pending measurement)

All numbers below are **[proposed target]**, not measurements. Latency percentiles are end-to-end from a TS client.

| Operation | p50 | p95 | Other |
|---|---|---|---|
| Point read (`get`, 1 shard) | < 300 ms | < 600 ms | Docs quote ~200 ms per query ([icc]) |
| Global ordered top-100 page, 16 shards | < 500 ms | < 1 s | Ladder step 1 (D6) |
| Global ordered top-100 page, 32 shards | < 600 ms | < 1.2 s | Ladder step 2 (D9) |
| Global ordered top-100 page, 64 shards | — | ≤ 1.5 s | Ladder step 3 = full benchmark scale (D7). **Exceeding this triggers building the global index tier (M6 go/no-go)** |
| Long sequential scan (`scan`/`ixScan` pages) | — | — | Pages up to ~1 MB per shard; ≥ 10k records/s per participating shard |
| Write cost per secondary index | — | — | < 20% extra instructions per write per index; **zero** inter-canister calls |
| `write` latency | ~1–2 s | — | Update path ([canisters]); not a target, an IC property |

**IC limits behind these targets (checked against [Resource limits][limits], 2026-11-13):**
- Query response size: **3 MiB** for non-replicated queries; 2 MiB for replicated execution (an update or a replicated query, e.g. `getCertainly`). A ~1 MB page fits under both, with room for Candid overhead. Our page cap is by bytes (default 1 MiB), not only by row count.
- Query instructions: **5 B** per query call. For composite queries the budget is shared across the whole evaluation, including callees (`MAX_CYCLES_PER_QUERY`, [IC spec][spec]).
- Stable memory read per query: 1 GiB. Not relevant to the EOP heap store, but it would cap a future Region-backed store.
- Throughput check: 10k records/s per shard at one ~1 MB page per ~200 ms round trip means ~2k records per page (~500 B/record) is enough, so the target leaves headroom. Instructions per scanned row must stay well under 5 B / rows-per-page (about 500 k instructions per row at 10k rows per page). **[unverified until M3 benchmarks]**

**Benchmark scale (D7):** 100 M records of ~1 KB (YCSB standard), 3 secondary indexes, 1,000 writes/s aggregate, on **64 shards** across **4 subnets × 16 shards**.

**Why 64 shards (arithmetic, not measured):**
- Raw values come to 100 M × ~1 KB ≈ 93 GiB. Keys, 3 index entries per record, B-tree slack and the EOP 64-bit layout (up to 2×, [changelog]) bring the estimate to roughly **120–190 GiB**.
- At the 2 GiB split trigger (§6) that needs about 60–95 shards. 64 shards means ~1.56 M records and ~1.5 GiB of raw values per shard, which fits under 2 GiB only if total overhead stays under ~1.35×.
- M3 measures real bytes per record. If the overhead is higher, the benchmark either runs at 96 shards (6 subnets × 16) or raises the split trigger to 3 GiB, still well under the 6 GiB heap limit. **[unverified until M3]**

**Why multiple subnets:**
- 1,000 writes/s on one subnet would compete for its 4 update threads and come close to its message budget (up to 1,000 messages per block at 1–3 blocks/s, [limits]).
- With 4 subnets, each subnet carries ~250 writes/s and each shard ~16 writes/s. Writes are batched by the client either way.
- Storage is not the constraint: ~150 GiB fits within one subnet's 2 TiB. But placing all of it on one subnet would push that subnet toward the 750 GiB reservation threshold together with other tenants ([cycles]).
- Query load for a 64-way fan-out is spread across 4 subnets' replicas instead of one subnet's 4 query threads per node.
- Composite-query gather (§5.4) works per subnet, which gives 4 gather calls per page instead of 64 shard calls.

**The ladder and the go/no-go point:**
- Because 64 shards is now the benchmark scale itself, the M6 go/no-go is decided by the main benchmark rather than by an extrapolation.
- The 16- and 32-shard targets remain useful as the **scaling curve**. They run with the same per-shard data size (~1.56 M records per shard, so 25 M and 50 M records total), which keeps per-shard work constant and isolates the fan-out effect.
- A 16-shard target alone would no longer predict the 64-shard result. The slope from 16 to 32 to 64 is what tells us whether, say, 128 shards would still be viable.

**Cost estimate on mainnet, for reference only: no mainnet runs are planned (D8)** (13-node subnets, cycle prices from [cycle costs][cycles], 1 T cycles = 1 XDR ≈ $1.37). These figures are **[unverified estimates]**: they assume ~3 M instructions per indexed 1 KB write, which M3 replaces with a measurement.

| Item | Cycles | ≈ USD |
|---|---|---|
| Create 64 shards (500 B each) | 32 T | ~$44 (one-off) |
| Initial balances (2 T each; spent only as used) | 128 T funded | ~$175 tied up, not spent |
| Load 100 M records, batched (~5.3 M cycles/write) | ~530 T | ~$720 (one-off) |
| Load 100 M records, unbatched (~11.4 M cycles/write) | ~1,140 T | ~$1,560 |
| 1 h steady run at 1,000 writes/s, batched | ~19 T | ~$26 per hour |
| Storage, 120–190 GiB (~329 B cycles per GiB-month) | 40–63 T/month | ~$55–85 per month |
| Queries (reads, scans, global pages) | 0 | free |

Per-write breakdown:
- **Unbatched:** 1.2 M ingress + 2.2 M for 1.1 KB of payload + 5 M update base + ~3 M instructions.
- **Batched ×100:** the per-message fees are amortized, leaving ~2.2 M + ~3 M + small overhead.

All benchmarks run on **PocketIC (free, multi-subnet)** (D8). Any future mainnet run, at full or reduced scale, would be a new decision needing the user's explicit approval and budget.

PocketIC and local replicas give instruction and message counts, not real network latency. Latency targets can only be confirmed by a mainnet run, which is out of scope for now (D8). On PocketIC, latency results are indicative only.

### 5.8 Computational complexity

Notation: n = records per shard, S = shards, k = results requested (page size), i = secondary indexes, m = records in a moved slot range (m ≤ n). All structures are `mo:core/Map` B-trees (order 32), so each lookup, insert or delete costs O(log n). The primary map has n entries; each index map has at most n entries.

| Operation | Per shard | Client / overall | Notes |
|---|---|---|---|
| Point read | O(log n) | Routing: O(1) slot hash + O(log S) binary search over cached slot ranges | 1 query, 1 shard |
| Range scan within a partition | O(log n + k) | — | 1 shard, because a `pk` lives on one shard |
| Global ordered page (scatter-gather) | O(log n + k) on **every** shard, in parallel | Merge O(k log S), plus O(S·k) to receive and decode | Fetches up to **S·k rows to return k** (S-fold overfetch) |
| Global page, adaptive mode | O(log n + ⌈c·k/S⌉) per shard per round | ~c·k rows fetched, occasionally a 2nd round | §5.3 |
| Write with i indexes | O((1 + 2i) log n) = O((1 + i) log n) | — | One message, **no inter-canister calls**. Overwrites delete the old index key and insert the new one (hence the 2i). Dedupe-table lookup adds O(log d) for d remembered request ids |
| Delete with i indexes | O((1 + i) log n) | — | Same message |
| Shard split / move | O(m) to copy, O(m (1 + i) log n′) to rebuild at the target | — | Incremental: background batches on a timer, each under the 40 B update instruction limit. Never one big message |
| Index backfill (new index) | O(n log n) per shard | All shards in parallel | Incremental batches, like a split |

**Corrections to the shorthand:**
- The client merge itself is O(k log S), but the client still has to receive and decode up to S·k rows. Its total work and bandwidth are therefore O(S·k). That overfetch, and the fact that every page touches all S shards, motivate the optional global index tier.
- A write with overwrites costs 1 + 2i tree operations (delete the old index key plus insert the new one). Asymptotically that is still O((1 + i) log n).
- A split costs O(m) for the moved range, not O(n) for the whole shard. In the worst case m ≈ n/2.

**For comparison, the optional global index tier (§5.1 (a)):** a page costs O(log n_g + k) on one or two index shards, with no S-fold overfetch. The price is that every write that changes an indexed value adds up to 2 inter-canister update calls per index, which is exactly what D6's "no inter-canister calls per index" target rules out for the default path.

---

## 6. Storage inside a shard

**Decision: EOP heap with `mo:core/Map<Blob, Entry>` for the primary data, keyed by `pk ‖ sk` with a length prefix, plus one `Map<Blob, ()>` per local index, keyed by `ixKey ‖ pk ‖ sk`.**

- **Pros:** no manual memory layout, native-speed access, upgrades independent of heap size, and type-checked upgrade compatibility ([EOP][eop]).
- **Cons:** capacity is bounded by the heap (6 GiB on wasm64), and EOP's 64-bit layout can use up to 2× more memory ([changelog][changelog]). We keep shards well under that: the 2 GiB split trigger leaves GC and migration headroom. Index entries add memory roughly proportional to (entries × indexes × key size), which counts toward the trigger.
- **Regions (stable memory), rejected for v1.**
  - The docs say to use them "only if enhanced orthogonal persistence does not fit your use case". Access is "significantly higher" cost, and layout and free-space management are manual ([Stable memory and regions][regions]).
  - The default page cap is inconsistent in the docs: the compiler reference says `--max-stable-pages` defaults to 100 GiB ([compiler ref][mocref]), while `core/Region.mo` says 4 GiB. **[unverified which applies]**
  - Storage sits behind a `Store` interface so that a Region-backed store can be added later, e.g. for large cold values.
- **Memory measurement:** heap size from the runtime (`Prim.rts_heap_size` / `rts_memory_size`) and `canister_status.memory_metrics` from the index. **[unverified: exact core API names]**
- Set `wasm_memory_limit` on each shard as a hard stop, plus `wasm_memory_threshold` so a low-memory hook fires early ([management canister][mgmt]). **[unverified: Motoko `system func lowmemory` support]**
- **Rescue path:** a controller-only `exportRange` query, as recommended in the EOP docs.

---

## 7. Access control

| Role | Who | Can |
|---|---|---|
| Admin | Controllers of the index (`Principal.isController`) | Everything in the index admin API |
| Writer | Principals on the allowlist (user principals or app canisters) | `write` on shards |
| Reader | `public`, or an allowlist (configurable) | `get`, `scan`, `ixScan` |
| Index | The index canister principal | Internal shard methods: assign slots, migrate, backfill, export |

- Shards hold their own copy of the allowlist, pushed by the index on change and versioned. Authorization is a local check, with no call on the hot path.
- Shard controllers are the index plus an optional operator principal kept as a break-glass rescue. The shard `status_visibility` is set to the index.
- `system func inspect` rejects ingress from non-writers early, which limits cycle drain from spam updates. It is a single-replica filter, so methods still re-check the caller.
- Internal methods check `caller == index` explicitly. This fixes v1's open `put` and `addKeyToShard`.

---

## 8. Cycles

Official costs on a 13-node subnet ([cycle costs][cycles]):

| Operation | Cost |
|---|---|
| Canister creation | 500 B cycles |
| Update base fee | 5 M cycles + 1 cycle per instruction |
| Ingress | 1.2 M per message + 2 K per byte |
| Inter-canister call | 260 K + 1 K per byte |
| Queries | free |
| Storage | ~329 B per GiB per month |

On the fiduciary subnet, multiply by ×2.6. Use the `ic0.cost_*` APIs instead of hard-coding these numbers ([management canister][mgmt]).

- **Data calls carry no cycles.** v1 attached 15 B cycles to each call (about 3,000× an update base fee), and this was removed. The receiving shard pays for ingress and execution from its own balance.
- Local indexes cost only the extra instructions inside the same message. A future GSI tier would add inter-canister calls per index change (§5.1); the benchmarks report cycles per write for both.
- **Creation:**
  - Same subnet: the index calls `create_canister` with `creation fee + initial balance` attached (default initial balance 2 T).
  - Another subnet: the management canister creates on the caller's subnet ([forum][subnetq]), so this goes through the CMC `create_canister` with `subnet_selection`. **[unverified: CMC call shape from a canister]** ([subnet selection][subsel])
- **Top-up:** a timer in the index (default every 10 min) reads each shard's `canister_status` (cycles, `idle_cycles_burned_per_day`, memory). It sends `deposit_cycles` when a shard's balance drops below `max(7 × daily burn, 1 T)`.
- **Freezing threshold** is left at the default of 30 days.
- **Index funding** is the operator's job. The index exposes its own projected runway, and `status()` raises a `lowCycles` flag well before shards would freeze.
- **Reserved cycles:** on subnets above 750 GiB, memory growth reserves cycles. Monitoring includes `reserved_cycles`, and subnet choice should avoid full subnets.

---

## 9. Upgrading child canisters

- **Wasm storage:** the operator uploads the shard wasm (which includes the user's `Schema`) to the index in chunks of 2 MiB or less, then calls `commitShardWasm(sha256)`. The index keeps the current and previous wasm.
  - Install uses `install_code` (a same-subnet request can be up to 10 MiB). For cross-subnet shards, or modules over the limit, use `upload_chunk` on the target plus `install_chunked_code` ([management canister][mgmt]).
- **Upgrade mode:** `#upgrade` with `wasm_memory_persistence = ?#keep`, which EOP requires. Never use `#reinstall` or `replace`, because both drop the heap ([EOP][eop]).
- **Rolling plan:**
  1. Snapshot (`take_canister_snapshot`, replacing the previous one).
  2. Stop the canister. Shards make no outgoing calls, so it drains fast.
  3. Upgrade.
  4. Start.
  5. Health check (`version()`, `schemaVersion`, sample `get`).

  Order: one canary shard, then batches of N. On failure, `load_canister_snapshot`, halt the plan, and report.
- **Compatibility rules:**
  - Shard Candid changes are additive only, so clients and mixed-version shards keep working during a roll. EOP also rejects incompatible stable-type changes on upgrade, which leaves the shard unchanged.
  - Schema changes are additive during a roll. A new index stays `#building` until every shard is upgraded and backfilled (§4.4).
  - Changing an existing index's `extract` means defining a new index id and dropping the old one later.
- A stopped shard is unavailable for about one round per upgrade. Clients see a reject and retry. A global scan that hits a stopped shard returns a retryable error rather than a silently incomplete page.

---

## 10. Consistency and failure modes

| Scope | Guarantee |
|---|---|
| Single key, update path | Linearizable (single-threaded canister, atomic message) |
| Batch on one shard | Atomic, all-or-nothing, including local index entries |
| Batch across shards | Per-shard atomic only. Partial success is reported per shard |
| Local index vs primary | Always consistent (same message) |
| `get`/`scan`/`ixScan` (query) | Answered by one replica: may lag slightly and is **not certified** (D2) |
| Global scan | Per-shard consistent. Not a snapshot across shards or pages (§5.6) |
| Read-your-writes | Use `getCertainly` (the same `get` sent as an update), ~1–2 s |

- **D2, certified reads out of scope.** Uncertified query reads are accepted for v1. A certified path would need a Merkle tree over each shard's data, served with the subnet's certificate through certified data. Proving range and index scans also needs completeness proofs. That is a substantial feature, so it is deferred; `getCertainly` (update path) covers the occasional need for consensus-backed reads.
- **Idempotency:** each `write` carries a client-chosen `requestId`. Shards keep a dedupe table (requestId → result) with a TTL (default 10 min), so retries after a timeout or a `SYS_UNKNOWN` are safe. CAS (`#version`) protects read-modify-write cycles.
- **Index orchestration across `await`s** (top-up, split, backfill, upgrade):
  - Each step is a persisted state machine with a per-range lock.
  - Steps are written idempotently, e.g. `assignSlots(epoch)` is a no-op if already applied.
  - State changes made before an `await` are not rolled back when the call is rejected, so state is committed before each `await` and re-checked after it.
  - Calls to our own shards use unbounded wait. Anything external, such as the CMC, uses bounded wait (`with timeout`) and treats `#system_unknown` as "check, then retry" ([Inter-canister calls][icc]).
- **Stale client map:** `#wrongShard` triggers a refresh and one retry. Correctness never depends on clients' maps being fresh, because shards are the authority. For global scans, the client re-fetches only the affected slice, using the same `after` cursor.
- **Shard out of cycles or frozen:** its slots become unavailable, and the error surfaces to clients. Global scans fail loudly instead of skipping that shard. The top-up margin (7 days of burn) and alerts are the mitigation. Data is not lost.
- **Index lost:** data traffic continues. A new index can rebuild the slot map from the shards, since each reports its own ranges and epoch.

---

## 11. Testing (local only, no mainnet)

- **Unit tests:** `mops test` covering:
  - the slot hash;
  - the order-preserving encoders (vectors shared with the TS client);
  - the Store and local index maintenance (overwrite and delete leave no stale entries);
  - CAS/dedupe;
  - the migration and backfill state machines;
  - the k-way merge and the cursor.
- **Integration tests:** `mops test --mode replica` on PocketIC (pinned version), plus `@dfinity/pic` from TypeScript for multi-canister and **multi-subnet** scenarios ([PocketIC][pic], [mops test][mopstest]). They cover:
  - put/get/delete/scan;
  - global `query`/`topN` equal to a sorted reference;
  - pagination across a split;
  - stale epoch → `#wrongShard`;
  - a split under concurrent writes, checked for no lost or duplicated writes or index rows;
  - index backfill;
  - upgrade with EOP keep, plus snapshot rollback;
  - top-up below threshold;
  - access-control negatives;
  - a trap injected mid-migration, followed by resume.
- **Property test:** random op sequences against an in-memory model with an index, with random splits and moves interleaved. Invariants:
  - the global scan equals the sorted model, where no concurrent writes occur;
  - every page is ordered;
  - no row appears twice within one shard slice.
- No mainnet deployments and no real cycles without the user's explicit approval.

---

## 12. Benchmark suite and demo (D3)

The suite is generic, synthetic and reproducible (seeded), and runs on PocketIC with multiple subnets. A local replica can be used for rough latency only.

| Workload | Mix | Purpose |
|---|---|---|
| YCSB-A | 50% read / 50% update, Zipfian keys | Update-heavy baseline |
| YCSB-B | 95% read / 5% update | Read-mostly |
| YCSB-C | 100% read | Point-read ceiling |
| YCSB-D | Read latest (insert + read recent) | Monotonic `sk`, hot recent data |
| YCSB-E | Short range scans within `pk` + inserts | Single-shard scans |
| IX-1 | Global `topN`/range pages on a numeric index, S = 1…64 | Fan-out scaling and the (b)→(a) crossover |
| IX-2 | Index-key churn (updates that change the indexed value) | Write cost of index maintenance |
| IX-3 | Skewed index values (few distinct values, Zipfian) | Tie-breaking and long ranges |
| Example: synthetic ad auction | Campaigns/ads with a `desc(price)` index; topN + price updates | One illustrative workload combining IX-1/IX-2. No special treatment in the library |

**Reported per workload:**
- instructions and cycles per op;
- messages per op;
- rows fetched vs returned (fan-out waste);
- per-shard and per-subnet ops/s ceilings (derived from instruction counts and the documented thread limits);
- index memory overhead.

**Scale and pass criteria:** the D7 dataset (100 M × ~1 KB records, 3 indexes, 1,000 writes/s aggregate, 64 shards on 4 PocketIC subnets) and the targets in §5.7, run as a ladder at 16, 32 and 64 shards with constant per-shard data. Smaller scales (1 M, 10 M records) run first in CI. Whether PocketIC on one box can hold ~150 GiB of state across 64 canisters is **[unverified]**. If it can't, the ladder uses the same per-shard size on fewer shards per run, and the full 64-shard run uses a reduced per-shard size (results labelled accordingly). Instruction-based targets (index write overhead, rows per page, records/s per shard derived from instructions) can be checked locally.

**Not measurable locally:** real network latency and boundary-node behaviour. Latency targets stay **[proposed target]**: no mainnet run is planned (D8).

**Demo:** a small TS script (and optional web page) that loads a synthetic dataset, declares two indexes, and shows point gets, a single-partition scan, and a paginated global top-N.

---

## 13. Milestones

| # | Deliverable | Done when |
|---|---|---|
| M0 | Repo skeleton (mops, moc pinned, PocketIC pinned). Slot hash and order-preserving encoders with cross-language vectors | `mops test` green |
| M1 | Single shard: Store on `core/Map`, write/get/scan/delete, CAS, dedupe, access control, **`Schema` and local indexes and `ixScan`** | Unit and replica tests green |
| M2 | Index canister plus static multi-shard: shard map query, epoch checks, TS client routing, **global `query`/`topN` via k-way merge and cursor** | Multi-shard tests: global scan equals reference |
| M3 | Cycles: create, top-up, status/metrics. **Benchmark harness, YCSB A–E and IX-1…3, synthetic data generator** | Baseline numbers recorded in `docs/BENCH.md` |
| M4 | Split/move protocol with crash-resume (local index entries move with their rows). **Index backfill/drop jobs** | Split-under-load test and scan-across-split test green |
| M5 | Wasm store and rolling upgrade with snapshots, multi-subnet placement (PocketIC), **optional per-subnet composite-query gather** | Upgrade/rollback tests green, IX-1 re-run multi-subnet |
| M6 | README, examples, demo (incl. the ad-auction example), v0.1.0 tag (local only, not published). **GSI decision gate:** go if the 64-shard global top-100 page p95 (the D7 benchmark scale) exceeds 1.5 s (D6), if the 16→32→64 ladder slope rules out larger deployments, or if the instruction-based targets fail | Review with the user |
| M7 | *(conditional on M6)* GSI tier: range-partitioned index shards, outbox propagation, lag metric, fallback to scatter-gather | Lag-bounded consistency tests green |

---

## 14. Open questions

None. The design is complete as of D1–D9. New questions found during implementation are added here.

---

## References

[limits]: https://docs.internetcomputer.org/references/resource-limits/
[cycles]: https://docs.internetcomputer.org/references/cycles-cost-formulas
[mgmt]: https://docs.internetcomputer.org/references/management-canister/
[canisters]: https://docs.internetcomputer.org/concepts/canisters/
[icc]: https://docs.internetcomputer.org/guides/canister-calls/inter-canister-calls/
[spec]: https://docs.internetcomputer.org/references/ic-interface-spec/
[eop]: https://docs.internetcomputer.org/languages/motoko/fundamentals/actors/orthogonal-persistence/enhanced/
[op]: https://docs.internetcomputer.org/languages/motoko/fundamentals/actors/orthogonal-persistence/overview/
[changelog]: https://docs.internetcomputer.org/languages/motoko/reference/changelog/
[regions]: https://docs.internetcomputer.org/languages/motoko/icp-features/stable-memory/
[mocref]: https://docs.internetcomputer.org/languages/motoko/reference/compiler-ref/
[subsel]: https://docs.internetcomputer.org/guides/canister-management/subnet-selection/
[subnetq]: https://forum.dfinity.org/t/in-which-subnet-does-ic-create-canister-create-a-canister/33279
[pic]: https://docs.internetcomputer.org/guides/testing/pocket-ic/
[mopstest]: https://docs.mops.one/cli/mops-test
[core]: https://github.com/caffeinelabs/motoko-core
[candb]: https://github.com/ORIGYN-SA/CanDB

- Resource limits: <https://docs.internetcomputer.org/references/resource-limits/>
- Cycle costs: <https://docs.internetcomputer.org/references/cycles-cost-formulas>
- Management canister: <https://docs.internetcomputer.org/references/management-canister/>
- Canisters (query/update/composite): <https://docs.internetcomputer.org/concepts/canisters/>
- Inter-canister calls (bounded wait, reentrancy): <https://docs.internetcomputer.org/guides/canister-calls/inter-canister-calls/>
- IC interface specification (composite query limits): <https://docs.internetcomputer.org/references/ic-interface-spec/>
- Enhanced orthogonal persistence: <https://docs.internetcomputer.org/languages/motoko/fundamentals/actors/orthogonal-persistence/enhanced/>
- Stable memory and regions: <https://docs.internetcomputer.org/languages/motoko/icp-features/stable-memory/>
- Subnet selection: <https://docs.internetcomputer.org/guides/canister-management/subnet-selection/>
- PocketIC: <https://docs.internetcomputer.org/guides/testing/pocket-ic/> · mops test: <https://docs.mops.one/cli/mops-test>
- motoko-core: <https://github.com/caffeinelabs/motoko-core> · CanDB: <https://github.com/ORIGYN-SA/CanDB>
