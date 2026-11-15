import { describe, test } from "node:test";
import assert from "node:assert/strict";
import * as E from "../src/encode.ts";
import {
  EkvmClient, applyChange, compareRows, double, even, move, shardForKey, shardIndexOfSlot, validate,
  type IndexActor, type IxRow, type ShardActor, type ShardMap,
} from "../src/index.ts";

const P = (s: string) => ({ toText: () => s });

describe("shard map changes (TS, mirrors ShardMap.mo)", () => {
  test("move reassigns exactly the moved slots", () => {
    const m = even(["a", "b", "c", "d"], 4, 1n);
    for (const [a, b, s] of [[0, 1, 3], [3, 9, 0], [12, 16, 0], [0, 16, 2], [5, 6, 1]] as const) {
      const n = move(m, a, b, s);
      assert.equal(validate(n), null);
      for (let slot = 0; slot < 16; slot++) {
        const want = slot >= a && slot < b ? s : shardIndexOfSlot(m, slot);
        assert.equal(shardIndexOfSlot(n, slot), want);
      }
    }
  });
  test("applyChange chain equals direct computation", () => {
    const m = even(["a", "b"], 3, 1n);
    const r = [{ double: null }, { addShard: "c" }, { move: { start: 0n, end: 2n, shard: 2 } }].reduce((x, c) => applyChange(x, c as any), m);
    assert.deepEqual(r, move({ ...double(m), shards: ["a", "b", "c"], epoch: 3n }, 0, 2, 2));
  });
});

// ---------------------------------------------------------------- fake cluster

type Row = { ixKey: Uint8Array; key: { pk: Uint8Array; sk: Uint8Array }; version: bigint; value: [] };
const posCmp = (a: Row, b: { ixKey: Uint8Array; key: { pk: Uint8Array; sk: Uint8Array } }) => compareRows(a, b);

function fakeCluster(nShards: number, rows: Row[], opts: { maxRows?: number; seed?: number } = {}) {
  let map: ShardMap<string> = even(Array.from({ length: nShards }, (_, i) => `s${i}`), 8, 1n);
  const base = map;
  const changes: any[] = [];
  let seed = opts.seed ?? 7;
  const rnd = (n: number) => { seed = (seed * 1103515245 + 12345) % 2147483648; return Math.floor(seed / 65536) % n; };
  let staleShard: string | null = null; // answers #wrongShard once
  const calls = { ixScan: 0, index: 0 };
  const index: IndexActor = {
    async shardMap() { calls.index++; return { ...map, shards: map.shards.map(P), ranges: map.ranges.map(([f, s]) => [f, s]) } as any; },
    async shardMapSince(e) {
      calls.index++;
      if (e < base.epoch) return { full: await index.shardMap() };
      return { delta: { from: e, to: map.epoch, changes: changes.slice(Number(e - base.epoch)) } };
    },
  };
  const shard = (id: string): ShardActor => ({
    async ixScan(req: any) {
      calls.ixScan++;
      if (staleShard === id) { staleShard = null; return { err: { wrongShard: { epoch: map.epoch, slotBits: map.slotBits } } }; }
      if (req.route.epoch !== map.epoch) return { err: { wrongShard: { epoch: map.epoch, slotBits: map.slotBits } } };
      let mine = rows.filter((r) => shardForKey(map, r.key.pk) === id).sort(posCmp);
      if (req.reverse) mine.reverse();
      const after = req.after[0];
      if (after) mine = mine.filter((r) => (req.reverse ? posCmp(r, after) < 0 : posCmp(r, after) > 0));
      // simulate byte/instruction caps: sometimes return fewer rows with more = true
      const cap = Math.min(Number(req.limit), opts.maxRows ?? 1000, 1 + rnd(Number(req.limit)));
      const out = mine.slice(0, cap);
      return { ok: { rows: out, more: mine.length > cap } };
    },
    async write() { throw new Error("unused"); }, async get() { throw new Error("unused"); },
    async getCertainly() { throw new Error("unused"); }, async scan() { throw new Error("unused"); },
  });
  return {
    index, shard, calls,
    doubleNow() { map = double(map); changes.push({ double: null }); },
    makeStale(id: string) { staleShard = id; },
  };
}

const mkRows = (n: number): Row[] => Array.from({ length: n }, (_, i) => ({
  ixKey: E.nat64(BigInt((i * 7919) % 97)), key: { pk: E.text(`k${i}`), sk: E.nat32(i % 3) }, version: BigInt(i), value: [] as [],
}));
const hex = (rs: IxRow[]) => rs.map((r) => E.toHex(r.ixKey) + E.toHex(r.key.pk) + E.toHex(r.key.sk));

describe("global query merge (fake shards with random early stops)", () => {
  const rows = mkRows(500);
  const ref = [...rows].sort(posCmp);
  for (const perShard of [undefined, "adaptive" as const, 3]) {
    test(`paging equals reference, both directions (perShard=${perShard ?? "limit"})`, async () => {
      for (const reverse of [false, true]) {
        for (const limit of [1, 17, 100]) {
          const f = fakeCluster(6, rows, { seed: limit });
          const c = new EkvmClient({ index: f.index, shard: f.shard });
          const got: IxRow[] = [];
          for await (const r of c.queryAll(1, { limit, reverse, perShard })) got.push(r);
          assert.deepEqual(hex(got), hex(reverse ? [...ref].reverse() : ref));
        }
      }
    });
  }
  test("topN equals reference prefix; adaptive fetches fewer rows", async () => {
    const f1 = fakeCluster(16, rows, { maxRows: 1000, seed: 1 });
    const c1 = new EkvmClient({ index: f1.index, shard: f1.shard });
    const full = await c1.query(1, { limit: 50 });
    const f2 = fakeCluster(16, rows, { maxRows: 1000, seed: 1 });
    const c2 = new EkvmClient({ index: f2.index, shard: f2.shard });
    const ad = await c2.query(1, { limit: 50, perShard: "adaptive" });
    assert.deepEqual(hex(full.rows), hex(ref.slice(0, 50)));
    assert.deepEqual(hex(ad.rows), hex(full.rows));
    assert.ok(ad.stats.rowsFetched <= full.stats.rowsFetched);
  });
  test("wrongShard mid-page: delta refresh, page restarts, still exact; cursor survives doubling", async () => {
    const f = fakeCluster(4, rows);
    const c = new EkvmClient({ index: f.index, shard: f.shard });
    const p1 = await c.query(1, { limit: 40 });
    f.doubleNow(); // cached map is now stale
    const p2 = await c.query(1, { limit: 40, cursor: p1.cursor });
    assert.equal(c.counters.deltaFetches, 1);
    assert.ok(p2.stats.refreshes >= 1);
    assert.equal(c.map!.slotBits, 9);
    f.makeStale("s2");
    const p3 = await c.query(1, { limit: 40, cursor: p2.cursor });
    assert.deepEqual(hex([...p1.rows, ...p2.rows, ...p3.rows]), hex(ref.slice(0, 120)));
  });
  test("cursor for another index is refused", async () => {
    const f = fakeCluster(2, rows);
    const c = new EkvmClient({ index: f.index, shard: f.shard });
    const p = await c.query(1, { limit: 5 });
    await assert.rejects(c.query(2, { cursor: p.cursor }));
  });
});
