// Multi-shard client (M2): cached, lazily refreshed shard map (delta fetch),
// key routing, cross-shard batches, and the global ordered `query`/`topN`
// via scatter-gather k-way merge with a stateless cursor (DESIGN.md §3, §4.2, §5.3).
import { sha256 } from "@noble/hashes/sha2.js";
import { concat } from "./encode.ts";
import { activeShards, applyChange, route as routeOf, shardForKey, validate, type MapChange, type ShardMap } from "./shardMap.ts";
import {
  EkvmError, ShardClient, compareRows, decodeIxCursor, encodeIxCursor, newRequestId, unbounded,
  type Bound, type Cond, type Entry, type Err, type IxPos, type IxRow, type Key, type ScanOpts, type ShardActor, type WriteOp,
} from "./shard.ts";

/** Principal-like: anything with toText(), as returned by agents. */
type PrincipalLike = { toText(): string };
type WireMap = { epoch: bigint; slotBits: number; shards: PrincipalLike[]; ranges: [number, number][]; schemaVersion: bigint };
type WireChange = { double: null } | { move: { start: bigint; end: bigint; shard: number } } | { addShard: PrincipalLike };

export interface IndexActor {
  shardMap(): Promise<WireMap>;
  shardMapSince(epoch: bigint): Promise<{ delta: { from: bigint; to: bigint; changes: WireChange[] } } | { full: WireMap }>;
}

export type OpResult = { ok: bigint } | { err: Err };

export type QueryOpts = {
  from?: Bound; to?: Bound; limit?: number; reverse?: boolean; withValues?: boolean; cursor?: string | null;
  /**
   * Rows requested per shard per round. Default = limit (exact in one round
   * unless a shard hits its byte/instruction cap). Adaptive mode (§5.3):
   * ceil(c·limit/S), e.g. `perShard: "adaptive"` uses c = 2.
   */
  perShard?: number | "adaptive";
};
export type QueryStats = { shards: number; rounds: number; calls: number; rowsFetched: number; refreshes: number };
export type QueryPage = { rows: IxRow[]; cursor: string | null; stats: QueryStats };

const toMap = (m: WireMap): ShardMap<string> => ({
  epoch: m.epoch, slotBits: m.slotBits, schemaVersion: m.schemaVersion,
  shards: m.shards.map((p) => p.toText()), ranges: m.ranges.map(([f, s]) => [f, s] as const),
});
const toChange = (c: WireChange): MapChange<string> => ("addShard" in c ? { addShard: c.addShard.toText() } : c);
const isWrongShard = (e: unknown) => e instanceof EkvmError && "wrongShard" in e.err;
const keyOf = (op: WriteOp): Key => ("put" in op ? op.put.key : op.delete.key);

export class EkvmClient {
  readonly index: IndexActor;
  readonly shardActor: (canisterId: string) => ShardActor;
  readonly maxRetries: number;
  private map_: ShardMap<string> | null = null;
  private readonly actors = new Map<string, ShardActor>();
  /** Counters for tests and benchmarks. */
  readonly counters = { fullFetches: 0, deltaFetches: 0, wrongShard: 0 };

  constructor(opts: { index: IndexActor; shard: (canisterId: string) => ShardActor; maxRetries?: number }) {
    this.index = opts.index;
    this.shardActor = opts.shard;
    this.maxRetries = opts.maxRetries ?? 3;
  }

  get map(): ShardMap<string> | null { return this.map_; }

  /** Fetch the map: a delta from the cached epoch when possible, else the full map. */
  async refresh(): Promise<"full" | "delta" | "current"> {
    if (!this.map_) {
      this.setMap(toMap(await this.index.shardMap()));
      this.counters.fullFetches++;
      return "full";
    }
    const r = await this.index.shardMapSince(this.map_.epoch);
    if ("full" in r) {
      this.setMap(toMap(r.full));
      this.counters.fullFetches++;
      return "full";
    }
    if (r.delta.changes.length === 0) return "current";
    let m = this.map_;
    for (const c of r.delta.changes) m = applyChange(m, toChange(c));
    if (m.epoch !== r.delta.to) throw new Error("delta did not reach the advertised epoch");
    this.setMap(m);
    this.counters.deltaFetches++;
    return "delta";
  }

  private setMap(m: ShardMap<string>) {
    const err = validate(m);
    if (err) throw new Error(`invalid shard map: ${err}`);
    this.map_ = m;
  }

  private async ensureMap(): Promise<ShardMap<string>> {
    if (!this.map_) await this.refresh();
    return this.map_!;
  }

  private actor(id: string): ShardActor {
    let a = this.actors.get(id);
    if (!a) { a = this.shardActor(id); this.actors.set(id, a); }
    return a;
  }

  private shard(id: string, m: ShardMap<string>): ShardClient {
    return new ShardClient(this.actor(id), () => routeOf(m), { schemaVersion: m.schemaVersion });
  }

  /** Run `fn` with the current map; on #wrongShard refresh and retry (bounded). */
  private async routed<T>(fn: (m: ShardMap<string>) => Promise<T>, stats?: { refreshes: number }): Promise<T> {
    for (let attempt = 0; ; attempt++) {
      const m = await this.ensureMap();
      try {
        return await fn(m);
      } catch (e) {
        if (!isWrongShard(e) || attempt >= this.maxRetries) throw e;
        this.counters.wrongShard++;
        if (stats) stats.refreshes++;
        await this.refresh();
      }
    }
  }

  // ------------------------------------------------------------ point operations

  async put(key: Key, value: Uint8Array, cond: Cond = { any: null }): Promise<bigint> {
    return this.routed((m) => this.shard(shardForKey(m, key.pk), m).put(key, value, cond));
  }

  async delete(key: Key, cond: Cond = { any: null }): Promise<bigint> {
    return this.routed((m) => this.shard(shardForKey(m, key.pk), m).delete(key, cond));
  }

  async getOne(key: Key, opts: { certain?: boolean } = {}): Promise<Entry | null> {
    return (await this.get([key], opts))[0]!;
  }

  /** Multi-key read: grouped by shard, shards queried in parallel; results in input order. */
  async get(keys: Key[], opts: { certain?: boolean } = {}): Promise<(Entry | null)[]> {
    const out: (Entry | null)[] = new Array(keys.length).fill(null);
    let pending = keys.map((_, i) => i);
    for (let attempt = 0; pending.length; attempt++) {
      const m = await this.ensureMap();
      const groups = groupBy(pending, (i) => shardForKey(m, keys[i]!.pk));
      const failed: number[] = [];
      await Promise.all([...groups].map(async ([id, idx]) => {
        try {
          const r = await this.shard(id, m).get(idx.map((i) => keys[i]!), opts);
          r.forEach((e, j) => { out[idx[j]!] = e; });
        } catch (e) {
          if (!isWrongShard(e) || attempt >= this.maxRetries) throw e;
          failed.push(...idx);
        }
      }));
      if (failed.length) { this.counters.wrongShard++; await this.refresh(); }
      pending = failed;
    }
    return out;
  }

  /**
   * Batch across shards: split by shard, sub-batches sent in parallel. Atomic
   * per shard only (DESIGN.md §10); the result reports each op. Sub-batch
   * request ids derive from `requestId` and the sub-batch composition, so
   * retrying the same call is deduplicated shard-side.
   */
  async batch(ops: WriteOp[], opts: { requestId?: Uint8Array; retries?: number } = {}): Promise<OpResult[]> {
    const base = opts.requestId ?? newRequestId();
    const out: OpResult[] = new Array(ops.length);
    let pending = ops.map((_, i) => i);
    for (let attempt = 0; pending.length; attempt++) {
      const m = await this.ensureMap();
      const groups = groupBy(pending, (i) => shardForKey(m, keyOf(ops[i]!).pk));
      const failed: number[] = [];
      await Promise.all([...groups].map(async ([id, idx]) => {
        const rid = subRequestId(base, id, idx);
        try {
          const v = await this.shard(id, m).batch(idx.map((i) => ops[i]!), { requestId: rid, retries: opts.retries });
          v.forEach((x, j) => { out[idx[j]!] = { ok: x }; });
        } catch (e) {
          if (isWrongShard(e) && attempt < this.maxRetries) { failed.push(...idx); return; }
          if (e instanceof EkvmError) { for (const i of idx) out[i] = { err: e.err }; return; }
          throw e;
        }
      }));
      if (failed.length) { this.counters.wrongShard++; await this.refresh(); }
      pending = failed;
    }
    return out;
  }

  /** One page of a partition scan (single shard). */
  async scan(pk: Uint8Array, opts: ScanOpts = {}): Promise<{ entries: Entry[]; cursor: string | null }> {
    return this.routed((m) => this.shard(shardForKey(m, pk), m).scan(pk, opts));
  }

  async *scanAll(pk: Uint8Array, opts: Omit<ScanOpts, "cursor"> = {}): AsyncGenerator<Entry> {
    let cursor: string | null = null;
    do {
      const p: { entries: Entry[]; cursor: string | null } = await this.scan(pk, { ...opts, cursor });
      yield* p.entries;
      cursor = p.cursor;
    } while (cursor);
  }

  // ------------------------------------------------------------ global ordered scans

  /**
   * Global ordered page over a local secondary index: every shard is asked
   * for its slice after the cursor position, the streams are k-way merged,
   * and a row is emitted only once no shard can still produce a smaller one
   * (exact, including when a shard stops early at its byte or instruction
   * cap). On #wrongShard the map is refreshed and the page restarts from the
   * same cursor position, which is a key-space position and survives map changes.
   */
  async query(index: number, opts: QueryOpts = {}): Promise<QueryPage> {
    const limit = Math.max(1, Math.min(opts.limit ?? 100, 1000));
    let { from = unbounded, to = unbounded, reverse = false } = opts;
    let start: IxPos | null = null;
    if (opts.cursor) {
      const c = decodeIxCursor(opts.cursor);
      if (c.index !== index) throw new Error("cursor belongs to another index");
      ({ from, to, reverse } = c);
      start = c.after;
    }
    const stats: QueryStats = { shards: 0, rounds: 0, calls: 0, rowsFetched: 0, refreshes: 0 };
    const cmp = reverse ? (a: IxPos, b: IxPos) => compareRows(b, a) : compareRows;
    const page = await this.routed(async (m) => {
      const shards = activeShards(m);
      stats.shards = shards.length;
      const per = opts.perShard === "adaptive" ? Math.ceil((2 * limit) / shards.length)
        : Math.max(1, Math.min(opts.perShard ?? limit, 1000));
      const st = shards.map((id) => ({ id, rows: [] as IxRow[], more: true, after: start }));
      const r = routeOf(m);
      for (;;) {
        // Lower bound on anything a shard has not delivered yet: its last row.
        const merged = st.flatMap((s) => s.rows).sort(cmp);
        const open = st.filter((s) => s.more);
        const frontier = (s: (typeof st)[number]) => s.rows.length ? s.rows[s.rows.length - 1]! : null;
        const safe = (row: IxRow) => open.every((s) => { const f = frontier(s); return f !== null && cmp(row, f) <= 0; });
        let n = 0;
        while (n < merged.length && n < limit && safe(merged[n]!)) n++;
        if (n >= limit || open.length === 0) {
          const rows = merged.slice(0, limit);
          const more = open.length > 0 || merged.length > limit;
          return { rows, more };
        }
        // Fetch from open shards that can still contribute before the limit-th row.
        const target = merged.length >= limit ? merged[limit - 1]! : null;
        const need = open.filter((s) => { const f = frontier(s); return f === null || target === null || cmp(f, target) < 0; });
        stats.rounds++;
        await Promise.all(need.map(async (s) => {
          const res = await this.actor(s.id).ixScan({
            route: r, index, from, to, after: s.after ? [s.after] : [], limit: BigInt(per), reverse, withValues: opts.withValues ?? false,
          });
          stats.calls++;
          if ("err" in res) throw new EkvmError(res.err);
          s.rows.push(...res.ok.rows);
          stats.rowsFetched += res.ok.rows.length;
          s.more = res.ok.more;
          const last = res.ok.rows[res.ok.rows.length - 1];
          if (last) s.after = { ixKey: last.ixKey, key: last.key };
          else if (s.more) throw new Error("shard returned no rows but more = true");
        }));
      }
    }, stats);
    const m = this.map_!;
    const last = page.rows[page.rows.length - 1];
    const cursor = page.more && last
      ? encodeIxCursor({ v: 1, index, schemaVersion: m.schemaVersion, from, to, reverse, after: { ixKey: last.ixKey, key: last.key }, epoch: m.epoch, slotBits: m.slotBits })
      : null;
    return { rows: page.rows, cursor, stats };
  }

  async *queryAll(index: number, opts: Omit<QueryOpts, "cursor"> = {}): AsyncGenerator<IxRow> {
    let cursor: string | null = null;
    do {
      const p: QueryPage = await this.query(index, { ...opts, cursor });
      yield* p.rows;
      cursor = p.cursor;
    } while (cursor);
  }

  /** First n rows of an index in global order (DESIGN.md §3). */
  async topN(index: number, n: number, opts: Omit<QueryOpts, "cursor" | "limit"> = {}): Promise<IxRow[]> {
    return (await this.query(index, { ...opts, limit: n })).rows;
  }
}

function groupBy<T>(xs: T[], key: (x: T) => string): Map<string, T[]> {
  const g = new Map<string, T[]>();
  for (const x of xs) { const k = key(x); const a = g.get(k); if (a) a.push(x); else g.set(k, [x]); }
  return g;
}

/** Deterministic per-shard request id: SHA-256(base ‖ shard ‖ op indexes), 16 bytes. */
function subRequestId(base: Uint8Array, shard: string, idx: number[]): Uint8Array {
  const enc = new TextEncoder();
  return sha256(concat(base, enc.encode(`|${shard}|${idx.join(",")}`))).subarray(0, 16);
}


