// M2 on PocketIC (local only): index + 8 shards over 2 subnets (4 + 4), the
// TS client routing keys and running global ordered queries via k-way merge,
// lazy delta refresh, and a zero-movement slot doubling rollout.
import { after, before, describe, test } from "node:test";
import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { PocketIc, PocketIcServer, SubnetStateType, createIdentity } from "@dfinity/pic";
import { Principal } from "@icp-sdk/core/principal";
import { indexIdl, shardIdl, shardInit } from "../src/idl.ts";
import * as E from "../src/encode.ts";
import { EkvmClient, compareRows, excl, incl, shardForKey, type IxRow, type Key, type WriteOp } from "../src/index.ts";
import { IX, decodeItem, encodeItem, type Item } from "./demo.ts";

const wasm = (n: string) => new URL(`../../build/${n}.wasm`, import.meta.url).pathname;
const out = new URL("../../build/bench-m2.json", import.meta.url).pathname;
const admin = createIdentity("ekvm-m2-admin");
const writer = createIdentity("ekvm-m2-writer");
const SHARDS = 8;
const ITEMS = 2000;
const cats = ["books", "games", "tools", "toys", "food"];

let server: PocketIcServer;
let pic: PocketIc;
let index: any;
let shardIds: Principal[] = [];
const model = new Map<string, { key: Key; item: Item }>();
const kid = (k: Key) => E.toHex(k.pk) + "/" + E.toHex(k.sk);

const newClient = (id = writer) => new EkvmClient({
  index,
  shard: (cid) => { const a: any = pic.createActor({ idlFactory: shardIdl, canisterId: Principal.fromText(cid) }); a.setIdentity(id); return a; },
});

before(async () => {
  server = await PocketIcServer.start({ binPath: process.env.POCKET_IC_BIN, showRuntimeLogs: false });
  pic = await PocketIc.create(server.getUrl(), {
    application: [{ state: { type: SubnetStateType.New } }, { state: { type: SubnetStateType.New } }],
  });
  const subnets = await pic.getApplicationSubnets();
  const ix = await pic.setupCanister({ idlFactory: indexIdl, wasm: wasm("index"), sender: admin.getPrincipal(), targetSubnetId: subnets[0]!.id });
  index = ix.actor;
  index.setIdentity(admin);
  for (let i = 0; i < SHARDS; i++) {
    const s = await pic.setupCanister({ idlFactory: shardIdl, wasm: wasm("shard-ix3"), sender: admin.getPrincipal(), arg: shardInit(ix.canisterId), targetSubnetId: subnets[i % 2]!.id });
    shardIds.push(s.canisterId);
  }
  await index.registerShards(shardIds, 16);
  await index.addWriter(writer.getPrincipal());
});

after(async () => {
  await pic?.tearDown();
  await server?.stop();
});

const item = (i: number, v = 0): Item => ({
  name: `name-${String((i * 7919 + v) % 10007).padStart(5, "0")}`, category: cats[(i + v) % cats.length]!,
  price: BigInt((i * 31 + v * 17) % 500), payload: new Uint8Array(100).fill(i & 0xff),
});
const ixKeyOf = (ixId: number, it: Item) =>
  ixId === IX.byPrice ? E.nat64(it.price)
  : ixId === IX.byCategoryPrice ? E.tuple(E.text(it.category), E.desc(E.nat64(it.price)))
  : E.text(it.name);
const reference = (ixId: number, filter: (it: Item) => boolean = () => true) =>
  [...model.values()].filter((m) => filter(m.item)).map((m) => ({ ixKey: ixKeyOf(ixId, m.item), key: m.key })).sort(compareRows);
const hex = (rs: { ixKey: Uint8Array; key: Key }[]) => rs.map((r) => E.toHex(r.ixKey) + "|" + kid(r.key));
const collect = async (it: AsyncGenerator<IxRow>) => { const a: IxRow[] = []; for await (const r of it) a.push(r); return a; };
const measured: Record<string, unknown> = {};

describe("M2 multi-shard routing (PocketIC, 8 shards, 2 subnets)", () => {
  test("index rejects re-registration and non-controller admin", async () => {
    await assert.rejects(index.registerShards(shardIds, 16));
    const stranger = createIdentity("ekvm-m2-stranger");
    index.setIdentity(stranger);
    await assert.rejects(index.doubleSlots());
    index.setIdentity(admin);
    assert.equal((await index.status()).shards, BigInt(SHARDS));
  });

  test("cross-shard batch load; every shard gets data", async () => {
    const c = newClient();
    for (let b = 0; b < ITEMS; b += 250) {
      const ops: WriteOp[] = [];
      for (let i = b; i < b + 250; i++) {
        const key = { pk: E.tuple(E.text("item"), E.nat32(i)), sk: E.text("v") };
        const it = item(i);
        model.set(kid(key), { key, item: it });
        ops.push({ put: { key, value: encodeItem(it), cond: { absent: null } } });
      }
      const r = await c.batch(ops);
      assert.ok(r.every((x) => "ok" in x));
    }
    let total = 0n;
    for (const id of shardIds) {
      const a: any = pic.createActor({ idlFactory: shardIdl, canisterId: id });
      const st = await a.stats();
      assert.ok(st.entries > 0n);
      total += st.entries;
    }
    assert.equal(total, BigInt(ITEMS));
  });

  test("multi-key get across shards keeps input order", async () => {
    const c = newClient();
    const keys = [...model.values()].slice(0, 300).map((m) => m.key).reverse();
    const got = await c.get([...keys, { pk: E.text("missing"), sk: E.text("") }]);
    assert.equal(got.length, 301);
    assert.equal(got[300], null);
    got.slice(0, 300).forEach((e, i) => assert.deepEqual(e!.key, keys[i]));
  });

  test("cross-shard batch is atomic per shard only; failures reported per op", async () => {
    const c = newClient();
    const m = await c.refresh().then(() => c.map!);
    const [a, b] = [...model.values()].filter((x, _, all) => shardForKey(m, x.key.pk) !== shardForKey(m, all[0]!.key.pk) || x === all[0]).slice(0, 2);
    const sameShardAsA = [...model.values()].find((x) => x !== a && shardForKey(m, x.key.pk) === shardForKey(m, a!.key.pk))!;
    // a's shard: one op conflicts -> whole sub-batch rejected; b's shard applies.
    const r = await c.batch([
      { put: { key: a!.key, value: encodeItem(a!.item), cond: { absent: null } } },           // conflict
      { put: { key: sameShardAsA.key, value: encodeItem(sameShardAsA.item), cond: { any: null } } }, // same shard, rolled back
      { put: { key: b!.key, value: encodeItem(b!.item), cond: { any: null } } },                // other shard, applied
    ]);
    assert.ok("err" in r[0]! && "conflict" in r[0].err);
    assert.ok("err" in r[1]! && "conflict" in r[1].err);
    assert.ok("ok" in r[2]!);
  });
});

describe("M2 global ordered query (PocketIC)", () => {
  for (const ixId of [IX.byPrice, IX.byCategoryPrice, IX.byName]) {
    test(`index ${ixId}: paging through all rows equals the global reference (limit 37)`, async () => {
      const c = newClient();
      const got = await collect(c.queryAll(ixId, { limit: 37 }));
      assert.deepEqual(hex(got), hex(reference(ixId)));
    });
  }

  test("reverse + value range + values", async () => {
    const c = newClient();
    const got = await collect(c.queryAll(IX.byPrice, { from: incl(E.nat64(100)), to: excl(E.nat64(200)), reverse: true, withValues: true, limit: 50 }));
    assert.deepEqual(hex(got), hex(reference(IX.byPrice, (it) => it.price >= 100n && it.price < 200n).reverse()));
    for (const r of got) assert.equal(E.decodeNat64(r.ixKey), decodeItem(r.value[0]!).price);
  });

  test("tuple prefix: one category, most expensive first", async () => {
    const c = newClient();
    const cat = E.text("games");
    const got = await collect(c.queryAll(IX.byCategoryPrice, { from: incl(cat), to: incl(cat), limit: 64 }));
    assert.deepEqual(hex(got), hex(reference(IX.byCategoryPrice, (it) => it.category === "games")));
  });

  test("topN(100): exact and adaptive agree with the reference [PocketIC measurement]", async () => {
    const c = newClient();
    await c.refresh();
    const ref = hex(reference(IX.byName).slice(0, 100));
    const t0 = performance.now();
    const exact = await c.query(IX.byName, { limit: 100 });
    const t1 = performance.now();
    const adaptive = await c.query(IX.byName, { limit: 100, perShard: "adaptive" });
    const t2 = performance.now();
    assert.deepEqual(hex(exact.rows), ref);
    assert.deepEqual(hex(adaptive.rows), ref);
    measured.topN100 = {
      note: "PocketIC measurement (local emulation; wall-clock is not IC latency)",
      shards: SHARDS, items: ITEMS,
      exact: { ...exact.stats, wallMs: Math.round(t1 - t0) },
      adaptive: { ...adaptive.stats, wallMs: Math.round(t2 - t1) },
    };
    console.log("topN(100) over", SHARDS, "shards [PocketIC measurement]:", JSON.stringify(measured.topN100));
  });

  test("index changes are visible globally (overwrite moves the row)", async () => {
    const c = newClient();
    const m = [...model.values()][5]!;
    const it = { ...m.item, price: 10_000n };
    await c.put(m.key, encodeItem(it));
    model.set(kid(m.key), { key: m.key, item: it });
    const top = await c.topN(IX.byPrice, 1, { reverse: true });
    assert.deepEqual(top[0]!.key, m.key);
  });
});

describe("M2 map refresh and slot doubling (PocketIC)", () => {
  test("delta fetch after doubling; stale clients keep working during and after the rollout", async () => {
    const stale = newClient();
    await stale.refresh();
    const before = stale.map!;
    const p1 = await stale.query(IX.byPrice, { limit: 300 }); // page before doubling
    const d = await index.doubleSlots();
    assert.equal(d.slotBits, 17);
    assert.equal(d.epoch, before.epoch + 1n);
    // During the rollout shards accept the old slotBits: point ops need no refresh.
    const k = [...model.values()][0]!;
    assert.ok(await stale.getOne(k.key));
    // ixScan also accepts the previous map (epoch - 1, old slotBits) during the rollout.
    assert.equal((await stale.query(IX.byPrice, { limit: 5 })).rows.length, 5);
    assert.equal(stale.counters.wrongShard, 0);
    // Delta: only the #double change is transferred.
    const since = await index.shardMapSince(before.epoch);
    assert.ok("delta" in since);
    assert.equal(since.delta.changes.length, 1);
    assert.ok("double" in since.delta.changes[0]);
    await index.finishDoubling();
    // Now the old slotBits are refused: the stale client refreshes via delta and retries.
    assert.ok(await stale.getOne(k.key));
    assert.equal(stale.counters.wrongShard, 1);
    assert.equal(stale.counters.deltaFetches, 1);
    assert.equal(stale.map!.slotBits, 17);
    const fresh = newClient();
    await fresh.refresh();
    assert.deepEqual(stale.map, fresh.map);
    // The pre-doubling cursor resumes on the new map; union equals the reference.
    const rest = await collect((async function* () {
      let cursor = p1.cursor;
      while (cursor) { const p = await stale.query(IX.byPrice, { limit: 300, cursor }); yield* p.rows; cursor = p.cursor; }
    })());
    assert.deepEqual(hex([...p1.rows, ...rest]), hex(reference(IX.byPrice)));
    // A client older than the log window base gets the full map.
    assert.ok("full" in (await index.shardMapSince(0n)));
    // Keys still route correctly under slotBits 17 for writes too.
    const key = { pk: E.text("after-doubling"), sk: E.text("x") };
    await fresh.put(key, encodeItem(item(1)));
    assert.ok(await stale.getOne(key));
  });

  test("record measurements", () => {
    writeFileSync(out, JSON.stringify(measured, null, 2));
  });
});
