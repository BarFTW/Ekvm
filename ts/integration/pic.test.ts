// PocketIC integration harness (local only, no real network, no real cycles).
// Two application subnets: index + shard A on subnet 0, shard B on subnet 1,
// so the index -> shard push is a cross-subnet call.
import { after, before, describe, test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { PocketIc, PocketIcServer, SubnetStateType, createIdentity } from "@dfinity/pic";
import type { Principal } from "@icp-sdk/core/principal";
import { indexIdl, shardIdl, shardInit } from "./idl.ts";
import * as E from "../src/encode.ts";
import { shardForKey, slotOfKey, validate, type ShardMap } from "../src/index.ts";

const wasm = (n: string) => new URL(`../../build/${n}.wasm`, import.meta.url).pathname;
const admin = createIdentity("ekvm-admin");
const stranger = createIdentity("ekvm-stranger");

let server: PocketIcServer;
let pic: PocketIc;
let index: any, shardA: any, shardB: any;
let ids: { index: Principal; a: Principal; b: Principal };

before(async () => {
  readFileSync(wasm("shard")); // fail fast if scripts/build.sh has not run
  server = await PocketIcServer.start({ binPath: process.env.POCKET_IC_BIN, showRuntimeLogs: false });
  pic = await PocketIc.create(server.getUrl(), {
    application: [{ state: { type: SubnetStateType.New } }, { state: { type: SubnetStateType.New } }],
  });
  const subnets = await pic.getApplicationSubnets();
  assert.equal(subnets.length, 2);
  const ix = await pic.setupCanister({ idlFactory: indexIdl, wasm: wasm("index"), sender: admin.getPrincipal(), targetSubnetId: subnets[0]!.id });
  const a = await pic.setupCanister({ idlFactory: shardIdl, wasm: wasm("shard"), sender: admin.getPrincipal(), arg: shardInit(ix.canisterId), targetSubnetId: subnets[0]!.id });
  const b = await pic.setupCanister({ idlFactory: shardIdl, wasm: wasm("shard"), sender: admin.getPrincipal(), arg: shardInit(ix.canisterId), targetSubnetId: subnets[1]!.id });
  index = ix.actor; shardA = a.actor; shardB = b.actor;
  ids = { index: ix.canisterId, a: a.canisterId, b: b.canisterId };
  index.setIdentity(admin);
});

after(async () => {
  await pic?.tearDown();
  await server?.stop();
});

const toMap = (m: any): ShardMap<string> => ({
  epoch: m.epoch, slotBits: m.slotBits, schemaVersion: m.schemaVersion,
  shards: m.shards.map((p: Principal) => p.toText()), ranges: m.ranges.map(([f, s]: [number, number]) => [f, s] as const),
});

describe("M0 skeleton on PocketIC (2 subnets)", () => {
  test("shards sit on different subnets", async () => {
    const sa = await pic.getCanisterSubnetId(ids.a), sb = await pic.getCanisterSubnetId(ids.b);
    assert.notEqual(sa?.toText(), sb?.toText());
    assert.equal(await index.version(), "ekvm-index/0.0.1 (M0)");
  });

  test("non-controller cannot register shards", async () => {
    index.setIdentity(stranger);
    await assert.rejects(index.registerShards([ids.a, ids.b], 16));
    index.setIdentity(admin);
  });

  test("register shards: map published and pushed cross-subnet", async () => {
    await index.registerShards([ids.a, ids.b], 16);
    const m = toMap(await index.shardMap());
    assert.equal(validate(m), null);
    assert.equal(m.epoch, 1n);
    assert.deepEqual(m.ranges, [[0, 0], [32768, 1]]);
    const st = await shardB.status();
    assert.equal(st.assignment.epoch, 1n);
    assert.deepEqual(st.assignment.owned, [[32768n, 65536n]]);
  });

  test("client routing agrees with shard-side route check", async () => {
    const m = toMap(await index.shardMap());
    const route = { epoch: m.epoch, slotBits: m.slotBits };
    for (let i = 0; i < 40; i++) {
      const pk = E.tuple(E.text("user"), E.nat64(i));
      const owner = shardForKey(m, pk) === ids.a.toText() ? shardA : shardB;
      const other = owner === shardA ? shardB : shardA;
      assert.deepEqual(await owner.routeCheck(route, pk), { ok: slotOfKey(pk, 16) });
      assert.deepEqual(await other.routeCheck(route, pk), { err: { wrongShard: { epoch: 1n, slotBits: 16 } } });
    }
  });

  test("stale slotBits gets #wrongShard, never misrouting", async () => {
    const pk = E.text("x");
    for (const s of [shardA, shardB]) {
      assert.deepEqual(await s.routeCheck({ epoch: 1n, slotBits: 15 }, pk), { err: { wrongShard: { epoch: 1n, slotBits: 16 } } });
    }
  });

  test("only the index may assign slots", async () => {
    shardA.setIdentity(admin);
    await assert.rejects(shardA.assign({ epoch: 9n, slotBits: 16, acceptPrevSlotBits: [], owned: [] }));
  });

  test("state survives an upgrade (wasm_memory_persistence = keep)", async () => {
    await pic.upgradeCanister({
      canisterId: ids.b, wasm: wasm("shard"), sender: admin.getPrincipal(), arg: shardInit(ids.index),
      upgradeModeOptions: { skip_pre_upgrade: [], wasm_memory_persistence: [{ keep: null }] },
    });
    const st = await shardB.status();
    assert.equal(st.assignment.epoch, 1n);
    assert.deepEqual(st.assignment.owned, [[32768n, 65536n]]);
  });
});
