// M1 on PocketIC (local only): single-shard data operations, local indexes,
// access control and dedupe. Index on subnet 0, shard A on subnet 0, shard B
// on subnet 1; both shards run the 3-index demo schema (build/shard-ix3.wasm).
import { after, before, describe, test } from "node:test";
import assert from "node:assert/strict";
import { PocketIc, PocketIcServer, SubnetStateType, createIdentity } from "@dfinity/pic";
import type { Principal } from "@icp-sdk/core/principal";
import { indexIdl, shardIdl, shardInit } from "../src/idl.ts";
import * as E from "../src/encode.ts";
import {
  EkvmError, ShardClient, compareRows, excl, incl, newRequestId, physicalIxKey, shardForKey, unbounded,
  type IxRow, type Key, type ShardMap,
} from "../src/index.ts";
import { IX, decodeItem, encodeItem, type Item } from "./demo.ts";

const wasm = (n: string) => new URL(`../../build/${n}.wasm`, import.meta.url).pathname;
const admin = createIdentity("ekvm-admin");
const writer = createIdentity("ekvm-writer");
const reader = createIdentity("ekvm-reader");
const stranger = createIdentity("ekvm-stranger");
const u = (s: string) => new TextEncoder().encode(s);

let server: PocketIcServer;
let pic: PocketIc;
let index: any;
let shards: Record<string, any> = {};
let ids: { index: Principal; a: Principal; b: Principal };
let map: ShardMap<string>;
const route = () => ({ epoch: map.epoch, slotBits: map.slotBits });
const actorFor = (pk: Uint8Array) => shards[shardForKey(map, pk)];
const clientFor = (pk: Uint8Array) => new ShardClient(actorFor(pk), route);
const both = () => [shards[ids.a.toText()], shards[ids.b.toText()]];
const asAll = (id: ReturnType<typeof createIdentity>) => both().forEach((s) => s.setIdentity(id));

before(async () => {
  server = await PocketIcServer.start({ binPath: process.env.POCKET_IC_BIN, showRuntimeLogs: false });
  pic = await PocketIc.create(server.getUrl(), {
    application: [{ state: { type: SubnetStateType.New } }, { state: { type: SubnetStateType.New } }],
  });
  const subnets = await pic.getApplicationSubnets();
  const ix = await pic.setupCanister({ idlFactory: indexIdl, wasm: wasm("index"), sender: admin.getPrincipal(), targetSubnetId: subnets[0]!.id });
  const mk = (sub: number) => pic.setupCanister({ idlFactory: shardIdl, wasm: wasm("shard-ix3"), sender: admin.getPrincipal(), arg: shardInit(ix.canisterId), targetSubnetId: subnets[sub]!.id });
  const a = await mk(0), b = await mk(1);
  index = ix.actor;
  index.setIdentity(admin);
  ids = { index: ix.canisterId, a: a.canisterId, b: b.canisterId };
  shards = { [a.canisterId.toText()]: a.actor, [b.canisterId.toText()]: b.actor };
  await index.registerShards([ids.a, ids.b], 16);
  const m = await index.shardMap();
  map = { epoch: m.epoch, slotBits: m.slotBits, schemaVersion: m.schemaVersion, shards: m.shards.map((p: Principal) => p.toText()), ranges: m.ranges };
});

after(async () => {
  await pic?.tearDown();
  await server?.stop();
});

const item = (name: string, category: string, price: number, payloadLen = 0): Uint8Array =>
  encodeItem({ name, category, price: BigInt(price), payload: new Uint8Array(payloadLen).fill(7) });

describe("M1 access control (PocketIC)", () => {
  test("writes need the allowlist pushed by the index", async () => {
    asAll(writer);
    const k = { pk: u("acl"), sk: u("1") };
    await assert.rejects(clientFor(k.pk).put(k, u("x")), /unauthorized|reject|Canister/i);
    await index.addWriter(writer.getPrincipal());
    assert.deepEqual((await index.getAccess()).writers.map((p: Principal) => p.toText()), [writer.getPrincipal().toText()]);
    for (const s of both()) assert.equal((await s.status()).accessVersion, 1n); // first allowlist version
    assert.ok((await clientFor(k.pk).put(k, u("x"))) > 0n);
  });

  test("non-writers are rejected (ingress filter or #unauthorized)", async () => {
    asAll(stranger);
    const k = { pk: u("acl"), sk: u("2") };
    await assert.rejects(clientFor(k.pk).put(k, u("x")));
    asAll(writer);
  });

  test("only controllers administer access; only the index pushes it", async () => {
    index.setIdentity(stranger);
    await assert.rejects(index.addWriter(stranger.getPrincipal()));
    index.setIdentity(admin);
    const s = both()[0];
    s.setIdentity(admin);
    await assert.rejects(s.setAccess({ version: 99n, writers: [admin.getPrincipal()], readers: { public: null } }));
    s.setIdentity(writer);
  });

  test("reader allowlist", async () => {
    const k = { pk: u("acl"), sk: u("1") };
    await index.setReaders({ allow: [reader.getPrincipal()] });
    asAll(stranger);
    await assert.rejects(clientFor(k.pk).getOne(k), (e: unknown) => e instanceof EkvmError && "unauthorized" in e.err);
    asAll(reader);
    assert.deepEqual((await clientFor(k.pk).getOne(k))?.value, u("x"));
    await index.setReaders({ public: null });
    asAll(stranger);
    assert.ok(await clientFor(k.pk).getOne(k));
    asAll(writer);
  });
});

describe("M1 data operations (PocketIC)", () => {
  test("put / get / getCertainly / delete with versions and CAS", async () => {
    const k = { pk: u("user/1"), sk: u("profile") };
    const c = clientFor(k.pk);
    const v1 = await c.put(k, u("a"), { absent: null });
    await assert.rejects(c.put(k, u("b"), { absent: null }), (e: unknown) =>
      e instanceof EkvmError && "conflict" in e.err && e.err.conflict.current[0] === v1);
    const v2 = await c.put(k, u("b"), { version: v1 });
    assert.ok(v2 > v1);
    assert.deepEqual(await c.getOne(k), { key: k, value: u("b"), version: v2 });
    assert.deepEqual((await c.getOne(k, { certain: true }))?.version, v2);
    await c.delete(k, { version: v2 });
    assert.equal(await c.getOne(k), null);
  });

  test("batch is all-or-nothing within a shard", async () => {
    const pk = u("batch");
    const c = clientFor(pk);
    const k1 = { pk, sk: u("1") }, k2 = { pk, sk: u("2") };
    await c.put(k2, u("old"));
    await assert.rejects(c.batch([
      { put: { key: k1, value: u("new"), cond: { any: null } } },
      { put: { key: k2, value: u("new"), cond: { absent: null } } },
    ]));
    assert.equal(await c.getOne(k1), null);
    assert.deepEqual((await c.getOne(k2))?.value, u("old"));
  });

  test("retrying with the same requestId is deduplicated", async () => {
    const pk = u("dedupe");
    const s = actorFor(pk);
    const requestId = newRequestId();
    const req = { route: route(), requestId, ops: [{ put: { key: { pk, sk: u("x") }, value: u("1"), cond: { absent: null } } }] };
    const r1 = await s.write(req);
    const r2 = await s.write(req); // would be #conflict if applied twice
    assert.deepEqual(r2, r1);
    assert.ok("ok" in r1);
  });

  test("misrouted keys and stale routes get #wrongShard", async () => {
    const pk = u("route-me");
    const owner = actorFor(pk);
    const other = both().find((s) => s !== owner);
    const r = await other.get({ route: route(), keys: [{ pk, sk: u("") }] });
    assert.deepEqual(r, { err: { wrongShard: { epoch: map.epoch, slotBits: 16 } } });
    const ix = await owner.ixScan({ route: { epoch: 0n, slotBits: 16 }, index: IX.byPrice, from: unbounded, to: unbounded, after: [], limit: 1n, reverse: false, withValues: false });
    assert.ok("err" in ix && "wrongShard" in ix.err);
  });

  test("partition scan with cursor, bounds and reverse", async () => {
    const pk = u("series");
    const c = clientFor(pk);
    const ops = Array.from({ length: 50 }, (_, i) => ({ put: { key: { pk, sk: E.nat32(i) }, value: new Uint8Array(1000).fill(i), cond: { any: null } } }));
    await c.batch(ops);
    const seen: number[] = [];
    let pages = 0, cursor: string | null = null;
    do {
      const p: { entries: any[]; cursor: string | null } = await c.scan(pk, { limit: 7, cursor });
      pages++;
      for (const e of p.entries) seen.push(Number(E.decodeNat64(new Uint8Array([0, 0, 0, 0, ...e.key.sk]))));
      cursor = p.cursor;
    } while (cursor);
    assert.deepEqual(seen, Array.from({ length: 50 }, (_, i) => i));
    assert.equal(pages, 8);
    const rev: number[] = [];
    for await (const e of c.scanAll(pk, { from: incl(E.nat32(10)), to: excl(E.nat32(20)), reverse: true, limit: 3 })) rev.push(e.value[0]!);
    assert.deepEqual(rev, [19, 18, 17, 16, 15, 14, 13, 12, 11, 10]);
  });

  test("page byte cap (1 MiB) splits large values across pages", async () => {
    const pk = u("big");
    const c = clientFor(pk);
    for (let i = 0; i < 3; i++) await c.put({ pk, sk: E.nat8(i) }, new Uint8Array(600_000).fill(i));
    const p1 = await c.scan(pk);
    assert.equal(p1.entries.length, 1);
    assert.ok(p1.cursor);
    let n = 0;
    for await (const _ of c.scanAll(pk)) n++;
    assert.equal(n, 3);
    await assert.rejects(c.put({ pk, sk: u("too-big") }, new Uint8Array(1_048_577)));
  });
});

describe("M1 local secondary indexes (PocketIC)", () => {
  const cats = ["books", "games", "tools", "toys"];
  const model = new Map<string, { key: Key; item: Item }>();
  const keyId = (k: Key) => E.toHex(k.pk) + "/" + E.toHex(k.sk);

  before(async () => {
    // 240 items over 60 partitions, spread over both shards; prices collide.
    const byShard = new Map<string, any[]>();
    for (let i = 0; i < 240; i++) {
      const key = { pk: u(`seller/${i % 60}`), sk: E.nat32(i) };
      const it = { name: `item-${String((i * 37) % 240).padStart(3, "0")}`, category: cats[i % 4]!, price: BigInt((i * 17) % 50), payload: new Uint8Array(0) };
      model.set(keyId(key), { key, item: it });
      const s = shardForKey(map, key.pk);
      byShard.set(s, [...(byShard.get(s) ?? []), { put: { key, value: encodeItem(it), cond: { any: null } } }]);
    }
    for (const [s, ops] of byShard) await new ShardClient(shards[s], route).batch(ops);
  });

  const scanShard = async (s: any, ixId: number, opts: any = {}) => {
    const rows: IxRow[] = [];
    for await (const r of new ShardClient(s, route).ixScanAll(ixId, opts)) rows.push(r);
    return rows;
  };
  const owned = (s: any) => [...model.values()].filter((m) => actorFor(m.key.pk) === s);

  test("each shard's by_price slice is in (price, pk, sk) order and complete", async () => {
    for (const s of both()) {
      const rows = await scanShard(s, IX.byPrice, { limit: 13 });
      const expect = owned(s).map((m) => E.toHex(physicalIxKey(E.nat64(m.item.price), m.key))).sort();
      assert.deepEqual(rows.map((r) => E.toHex(physicalIxKey(r.ixKey, r.key))), expect);
      for (let i = 1; i < rows.length; i++) assert.ok(compareRows(rows[i - 1]!, rows[i]!) < 0);
    }
  });

  test("client merge of both slices equals the global reference order (M2 preview)", async () => {
    const all = (await Promise.all(both().map((s) => scanShard(s, IX.byName)))).flat().sort(compareRows);
    const names = all.map((r) => E.decodeText(r.ixKey).value);
    assert.deepEqual(names, [...model.values()].map((m) => m.item.name).sort());
  });

  test("tuple prefix bound: one category by price descending, with values", async () => {
    const cat = E.text("games");
    const rows = (await Promise.all(both().map((s) => scanShard(s, IX.byCategoryPrice, { from: incl(cat), to: incl(cat), withValues: true, limit: 9 }))))
      .flat().sort(compareRows);
    assert.equal(rows.length, 60);
    const prices = rows.map((r) => decodeItem(r.value[0]!).price);
    assert.ok(rows.every((r) => decodeItem(r.value[0]!).category === "games"));
    for (let i = 1; i < prices.length; i++) assert.ok(prices[i - 1]! >= prices[i]!);
  });

  test("value range and reverse on by_price", async () => {
    for (const s of both()) {
      const rows = await scanShard(s, IX.byPrice, { from: incl(E.nat64(10)), to: excl(E.nat64(20)), reverse: true, limit: 5 });
      const expect = owned(s).filter((m) => m.item.price >= 10n && m.item.price < 20n).length;
      assert.equal(rows.length, expect);
      for (let i = 1; i < rows.length; i++) assert.ok(compareRows(rows[i - 1]!, rows[i]!) > 0);
    }
  });

  test("overwrite moves index entries; delete removes them", async () => {
    const m = [...model.values()][0]!;
    const c = clientFor(m.key.pk);
    await c.put(m.key, encodeItem({ ...m.item, price: 999n }));
    const top = await new ShardClient(actorFor(m.key.pk), route).ixScan(IX.byPrice, { reverse: true, limit: 1 });
    assert.deepEqual(top.rows[0]!.key, m.key);
    assert.equal(E.decodeNat64(top.rows[0]!.ixKey), 999n);
    await c.delete(m.key);
    const after = await scanShard(actorFor(m.key.pk), IX.byPrice, { from: incl(E.nat64(999)) });
    assert.equal(after.length, 0);
    const st = await actorFor(m.key.pk).stats();
    for (const ix of st.indexes) assert.equal(ix.entries, BigInt(owned(actorFor(m.key.pk)).length - 1));
    model.delete(keyId(m.key));
  });

  test("unknown index is reported", async () => {
    await assert.rejects(new ShardClient(both()[0], route).ixScan(42), (e: unknown) => e instanceof EkvmError && "unknownIndex" in e.err);
  });

  test("upgrade keeps data and indexes; schema change drops/adds indexes", async () => {
    const id = ids.b;
    const s = shards[id.toText()];
    const before = await s.stats();
    // setupCanister made admin the shard controller (index-as-controller arrives with M3 shard creation).
    const upAdmin = (w: string) => pic.upgradeCanister({
      canisterId: id, wasm: wasm(w), sender: admin.getPrincipal(), arg: shardInit(ids.index),
      upgradeModeOptions: { skip_pre_upgrade: [], wasm_memory_persistence: [{ keep: null }] },
    });
    await upAdmin("shard-ix3");
    const same = await s.stats();
    assert.equal(same.entries, before.entries);
    assert.deepEqual(same.indexes, before.indexes);
    await upAdmin("shard-ix2"); // drops by_name
    const s2 = await s.stats();
    assert.deepEqual(s2.indexes.map((i: any) => i.id), [1, 2]);
    assert.ok(s2.schemaLog.some((l: string) => l.startsWith("dropped index 3")));
    await upAdmin("shard-ix3"); // re-adds by_name on a non-empty shard: building until backfill (M4)
    const s3 = await s.stats();
    assert.deepEqual(s3.indexes.map((i: any) => [i.id, i.ready]), [[1, true], [2, true], [3, false]]);
    await assert.rejects(new ShardClient(s, route).ixScan(IX.byName), (e: unknown) => e instanceof EkvmError && "unknownIndex" in e.err);
    const rows = await scanShard(s, IX.byPrice);
    assert.equal(rows.length, owned(s).length);
  });
});
