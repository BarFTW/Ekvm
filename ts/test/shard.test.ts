import { describe, test } from "node:test";
import assert from "node:assert/strict";
import * as E from "../src/encode.ts";
import {
  ShardClient, EkvmError, compareRows, decodeIxCursor, decodeScanCursor, encodeIxCursor, encodeScanCursor,
  excl, incl, physicalIxKey, primaryKey, unbounded, type Bound, type Entry, type ShardActor,
} from "../src/shard.ts";

const u = (s: string) => new TextEncoder().encode(s);

describe("physical key layout (matches src/Store.mo)", () => {
  test("primary and index keys", () => {
    const k = { pk: Uint8Array.of(0x61, 0x00), sk: u("x") };
    assert.equal(E.toHex(primaryKey(k)), "6100ff000078");
    assert.equal(E.toHex(physicalIxKey(E.nat64(5), k)), "0000000000000005" + "6100ff000078");
  });
  test("component-wise row order equals byte order of the physical key", () => {
    const rows = [];
    for (const ix of [E.text("a"), E.text("a\0"), E.text("ab"), E.nat64(3)])
      for (const pk of [u("a"), Uint8Array.of(0x61, 0), u("ab"), u("")])
        for (const sk of [u(""), u("z"), Uint8Array.of(0)]) rows.push({ ixKey: ix, key: { pk, sk } });
    const a = [...rows].sort(compareRows).map((r) => E.toHex(physicalIxKey(r.ixKey, r.key)));
    const b = rows.map((r) => physicalIxKey(r.ixKey, r.key)).sort(E.compareBytes).map(E.toHex);
    assert.deepEqual(a, b);
  });
  test("pk is prefix-free: partition 'a' sorts entirely before 'a\\0' and 'ab'", () => {
    const keys = [{ pk: u("ab"), sk: u("") }, { pk: u("a"), sk: Uint8Array.of(0xff, 0xff) }, { pk: Uint8Array.of(0x61, 0), sk: u("") }];
    const sorted = keys.map(primaryKey).sort(E.compareBytes).map(E.toHex);
    assert.deepEqual(sorted, [primaryKey(keys[1]!), primaryKey(keys[2]!), primaryKey(keys[0]!)].map(E.toHex));
  });
});

describe("cursors", () => {
  test("scan cursor round-trip", () => {
    const c = { v: 1, pk: u("p"), from: incl(u("a")), to: unbounded, reverse: true, next: u("m") };
    assert.deepEqual(decodeScanCursor(encodeScanCursor(c)), c);
  });
  test("index cursor round-trip and version check", () => {
    const c = { v: 1, index: 3, schemaVersion: 7n, from: excl(u("a")), to: incl(u("z")), reverse: false, after: { ixKey: u("ix"), key: { pk: u("p"), sk: u("s") } }, epoch: 4n, slotBits: 16 };
    const s = encodeIxCursor(c);
    assert.match(s, /^[A-Za-z0-9_-]+$/);
    assert.deepEqual(decodeIxCursor(s), c);
    assert.throws(() => decodeIxCursor(encodeIxCursor({ ...c, v: 2 })));
  });
});

// In-memory fake shard: enough of the API to exercise client paging and retries.
const fakeShard = (entries: Entry[]): ShardActor & { calls: number; fails: number } => {
  const inRange = (sk: Uint8Array, from: Bound, to: Bound) =>
    ("incl" in from ? E.compareBytes(sk, from.incl) >= 0 : "excl" in from ? E.compareBytes(sk, from.excl) > 0 : true) &&
    ("incl" in to ? E.compareBytes(sk, to.incl) <= 0 : "excl" in to ? E.compareBytes(sk, to.excl) < 0 : true);
  const seen = new Map<string, bigint[]>();
  const self = {
    calls: 0, fails: 0,
    async write(req: any) {
      self.calls++;
      const id = E.toHex(req.requestId);
      if (!seen.has(id)) seen.set(id, [BigInt(seen.size + 1)]); // applied once per requestId
      if (self.fails > 0) { self.fails--; throw new Error("transport timeout"); } // reply lost
      return { ok: seen.get(id)! };
    },
    async get() { return { err: { unauthorized: null } } as const; },
    async getCertainly() { return { ok: [] }; },
    async scan(req: any) {
      let xs = entries.filter((e) => inRange(e.key.sk, req.from, req.to));
      if (req.reverse) xs = xs.reverse();
      const n = Number(req.limit) || 1000;
      const page = xs.slice(0, n);
      return { ok: { entries: page, next: xs.length > n ? [page[page.length - 1]!.key.sk] as [Uint8Array] : [] as [] } };
    },
    async ixScan() { return { ok: { rows: [], more: false } }; },
  };
  return self as any;
};

describe("ShardClient (fake shard)", () => {
  const es: Entry[] = Array.from({ length: 10 }, (_, i) => ({ key: { pk: u("p"), sk: E.nat8(i) }, value: u(`v${i}`), version: BigInt(i) }));
  const route = () => ({ epoch: 1n, slotBits: 16 });
  test("scanAll pages through a partition with cursors, both directions", async () => {
    const c = new ShardClient(fakeShard(es), route);
    const fwd: number[] = [];
    for await (const e of c.scanAll(u("p"), { limit: 3 })) fwd.push(e.key.sk[0]!);
    assert.deepEqual(fwd, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
    const rev: number[] = [];
    for await (const e of c.scanAll(u("p"), { limit: 4, reverse: true, from: incl(E.nat8(2)) })) rev.push(e.key.sk[0]!);
    assert.deepEqual(rev, [9, 8, 7, 6, 5, 4, 3, 2]);
  });
  test("retries reuse the requestId (dedupe makes them safe)", async () => {
    const s = fakeShard(es);
    s.fails = 2;
    const c = new ShardClient(s, route);
    assert.deepEqual(await c.batch([{ delete: { key: es[0]!.key, cond: { any: null } } }], { retries: 2 }), [1n]);
    assert.equal(s.calls, 3);
  });
  test("shard errors surface as EkvmError", async () => {
    const c = new ShardClient(fakeShard(es), route);
    await assert.rejects(c.getOne(es[0]!.key), (e: unknown) => e instanceof EkvmError && "unauthorized" in e.err);
  });
});
