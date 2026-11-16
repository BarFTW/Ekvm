// M3 on PocketIC (local only, simulated cycles, nothing real is spent): the
// index creates its shards (actor-class instantiation on its own subnet) and
// keeps them funded from canister_status (DESIGN.md §8).
import { after, before, describe, test } from "node:test";
import assert from "node:assert/strict";
import { PocketIc, PocketIcServer, SubnetStateType, createIdentity } from "@dfinity/pic";
import { Principal } from "@icp-sdk/core/principal";
import { indexIdl, shardIdl } from "../src/idl.ts";
import * as E from "../src/encode.ts";
import { EkvmClient, type WriteOp } from "../src/index.ts";
import { IX, encodeItem } from "./demo.ts";

const wasm = (n: string) => new URL(`../../build/${n}.wasm`, import.meta.url).pathname;
const admin = createIdentity("ekvm-m3-admin");
const writer = createIdentity("ekvm-m3-writer");
const T = 1_000_000_000_000n;
const INDEX_CYCLES = 100n * T;
const PER_SHARD = 1_200_000_000_000n; // 1.2 T incl. creation fee
const SHARDS = 4;

let server: PocketIcServer;
let pic: PocketIc;
let index: any;
let indexId: Principal;
let shards: Principal[] = [];

const basePolicy = {
  intervalNs: 600_000_000_000n, minBalance: T, burnDays: 7n, topUpFactor: 2n, indexReserve: T, lowRunwayDays: 30n,
};

before(async () => {
  server = await PocketIcServer.start({ binPath: process.env.POCKET_IC_BIN, showRuntimeLogs: false });
  pic = await PocketIc.create(server.getUrl(), { application: [{ state: { type: SubnetStateType.New } }] });
  const subnets = await pic.getApplicationSubnets();
  const ix = await pic.setupCanister({ idlFactory: indexIdl, wasm: wasm("index-ix3"), sender: admin.getPrincipal(), targetSubnetId: subnets[0]!.id, cycles: INDEX_CYCLES });
  index = ix.actor;
  indexId = ix.canisterId;
  index.setIdentity(admin);
});

after(async () => {
  await pic?.tearDown();
  await server?.stop();
});

describe("M3 shard creation and cycles management (PocketIC, simulated cycles)", () => {
  test("createShards: controller only, balance checked, then shards created and registered", async () => {
    const stranger = createIdentity("ekvm-m3-stranger");
    index.setIdentity(stranger);
    await assert.rejects(index.createShards(BigInt(SHARDS), 8, { cyclesPerShard: PER_SHARD, ixLayout: [] }));
    index.setIdentity(admin);
    // 200 shards × 1.2 T > 100 T: refused before creating anything
    await assert.rejects(index.createShards(200n, 8, { cyclesPerShard: PER_SHARD, ixLayout: [] }));
    const before = BigInt(await pic.getCyclesBalance(indexId));
    shards = await index.createShards(BigInt(SHARDS), 8, { cyclesPerShard: PER_SHARD, ixLayout: [] });
    assert.equal(shards.length, SHARDS);
    const after = BigInt(await pic.getCyclesBalance(indexId));
    assert.ok(before - after >= BigInt(SHARDS) * PER_SHARD, "index paid for the shards");
    const st = await index.status();
    assert.equal(st.shards, BigInt(SHARDS));
    assert.equal(st.slotBits, 8);
    for (const p of shards) {
      const s: any = pic.createActor({ idlFactory: shardIdl, canisterId: p });
      assert.match(await s.version(), /M3/);
      const ss = await s.status();
      assert.equal(ss.index.toText(), indexId.toText());
      assert.ok(ss.assignment.owned.length > 0);
      const stats = await s.stats();
      assert.equal(stats.indexes.length, 3, "embedded shard carries the index build's schema");
      assert.ok("prefix" in stats.ixLayout);
      const bal = BigInt(await pic.getCyclesBalance(p));
      assert.ok(bal > 0n && bal < PER_SHARD, `shard balance ${bal} = attached minus creation fee`);
    }
    await assert.rejects(index.createShards(1n, 8, { cyclesPerShard: PER_SHARD, ixLayout: [] }), "once only");
  });

  test("data path through created shards", async () => {
    await index.addWriter(writer.getPrincipal());
    const c = new EkvmClient({
      index,
      shard: (cid) => { const a: any = pic.createActor({ idlFactory: shardIdl, canisterId: Principal.fromText(cid) }); a.setIdentity(writer); return a; },
    });
    const ops: WriteOp[] = Array.from({ length: 200 }, (_, i) => ({
      put: { key: { pk: E.tuple(E.text("u"), E.nat64(i)), sk: E.text("r") }, value: encodeItem({ name: `n${i}`, category: "c", price: BigInt(i), payload: new Uint8Array(10) }), cond: { any: null } },
    }));
    await c.batch(ops);
    const top = await c.topN(IX.byPrice, 5, { reverse: true });
    assert.deepEqual(top.map((r) => E.toHex(r.ixKey)), [199, 198, 197, 196, 195].map((p) => E.toHex(E.nat64(BigInt(p)))));
  });

  test("checkCyclesNow tops up shards below threshold and records status", async () => {
    await index.setCyclesPolicy(basePolicy);
    const before = await Promise.all(shards.map((p) => pic.getCyclesBalance(p)));
    for (const b of before) assert.ok(b < T, "fresh shards are below the 1 T floor");
    const report: any[] = await index.checkCyclesNow();
    assert.equal(report.length, SHARDS);
    for (const [i, r] of report.entries()) {
      assert.equal(r.shard.toText(), shards[i]!.toText());
      assert.equal(r.topUps, 1n);
      assert.deepEqual(r.lastError, []);
      assert.ok(r.memorySize > 0n);
      const bal = BigInt(await pic.getCyclesBalance(shards[i]!));
      assert.ok(bal >= 2n * T - 10_000_000_000n, `topped up to ~2 T, got ${bal}`);
    }
    // Above threshold now: a second pass does nothing.
    const again: any[] = await index.checkCyclesNow();
    for (const r of again) assert.equal(r.topUps, 1n);
    const st = await index.status();
    assert.equal(st.lowCycles, false);
  });

  test("the timer runs the check; a starving index reports instead of overdrawing", async () => {
    await index.setCyclesPolicy({ ...basePolicy, intervalNs: 60_000_000_000n, minBalance: 3n * T });
    const c0 = (await index.shardCycleStatus()).checks;
    await pic.advanceTime(61_000);
    await pic.tick(30);
    const s1 = await index.shardCycleStatus();
    assert.ok(s1.checks > c0, "timer fired");
    for (const r of s1.shards) assert.equal(r.topUps, 2n);
    // Reserve larger than the balance: no deposit, error recorded, lowCycles raised.
    await index.setCyclesPolicy({ ...basePolicy, minBalance: 100n * T, indexReserve: 1000n * T });
    const bal0 = BigInt(await pic.getCyclesBalance(indexId));
    const r: any[] = await index.checkCyclesNow();
    for (const x of r) assert.match(x.lastError[0] ?? "", /too low/);
    assert.ok(BigInt(await pic.getCyclesBalance(indexId)) <= bal0);
    assert.equal((await index.status()).lowCycles, true);
    await index.setCyclesPolicy(basePolicy);
  });

  test("policy validation and controller checks", async () => {
    await assert.rejects(index.setCyclesPolicy({ ...basePolicy, intervalNs: 1n }));
    index.setIdentity(writer);
    await assert.rejects(index.checkCyclesNow());
    await assert.rejects(index.setCyclesPolicy(basePolicy));
    index.setIdentity(admin);
    assert.equal((await index.cyclesPolicy()).minBalance, T);
  });
});
