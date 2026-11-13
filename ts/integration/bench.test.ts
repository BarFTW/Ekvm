// D6 per-index write overhead, measured on PocketIC (local replica emulation,
// NOT mainnet). The same shard code is built with 0..3 demo indexes
// (build/shard-ix{0..3}.wasm). Each write's instruction count is the shard's
// own ic0.performance_counter(0) at the end of `write` (excludes reply
// encoding). Results are printed and written to build/bench-m1.json.
import { after, before, describe, test } from "node:test";
import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { PocketIc, PocketIcServer, SubnetStateType, createIdentity } from "@dfinity/pic";
import { shardIdl, shardInit } from "../src/idl.ts";
import * as E from "../src/encode.ts";
import { ShardClient, type WriteOp } from "../src/index.ts";
import { encodeItem } from "./demo.ts";

const wasm = (n: string) => new URL(`../../build/${n}.wasm`, import.meta.url).pathname;
const out = new URL("../../build/bench-m1.json", import.meta.url).pathname;
const admin = createIdentity("ekvm-bench-admin");
const PRELOAD = Number(process.env.EKVM_BENCH_PRELOAD ?? 20_000);
const N = Number(process.env.EKVM_BENCH_N ?? 200);
const cats = ["books", "games", "tools", "toys", "food", "music", "garden", "sport"];

let server: PocketIcServer;
let pic: PocketIc;
before(async () => {
  server = await PocketIcServer.start({ binPath: process.env.POCKET_IC_BIN, showRuntimeLogs: false });
  pic = await PocketIc.create(server.getUrl(), { application: [{ state: { type: SubnetStateType.New } }] });
});
after(async () => {
  await pic?.tearDown();
  await server?.stop();
});

// ~1 KB records (D7): Candid Item with a 950-byte payload.
const rec = (i: number, v: number) => encodeItem({
  name: `name-${(i * 7919 + v) % 1_000_003}`, category: cats[(i + v) % cats.length]!,
  price: BigInt((i * 31 + v * 17) % 100_000), payload: new Uint8Array(950).fill((i + v) & 0xff),
});
const key = (i: number) => ({ pk: E.tuple(E.text("user"), E.nat64(i)), sk: E.text("rec") });

type Phase = { perMessage: number; perOp: number; storePerOp: number; ops: number };
const results: Record<string, Record<string, Phase>> = {};

describe("D6 per-index write overhead (PocketIC measurement)", () => {
  for (const k of [0, 1, 2, 3]) {
    test(`shard with ${k} index(es)`, async () => {
      const subnets = await pic.getApplicationSubnets();
      // The bench shard's "index" is the admin identity, so it can assign slots and access directly.
      const f = await pic.setupCanister({ idlFactory: shardIdl, wasm: wasm(`shard-ix${k}`), sender: admin.getPrincipal(), arg: shardInit(admin.getPrincipal()), targetSubnetId: subnets[0]!.id });
      const s: any = f.actor;
      s.setIdentity(admin);
      await s.assign({ epoch: 1n, slotBits: 16, acceptPrevSlotBits: [], owned: [[0n, 65536n]] });
      await s.setAccess({ version: 1n, writers: [admin.getPrincipal()], readers: { public: null } });
      const c = new ShardClient(s, () => ({ epoch: 1n, slotBits: 16 }));
      const phases: Record<string, Phase> = {};
      const measure = async (name: string, run: () => Promise<void>) => {
        const a = await s.stats();
        await run();
        const b = await s.stats();
        const ins = Number(b.writeInstructions - a.writeInstructions);
        const msgs = Number(b.writeCalls - a.writeCalls), ops = Number(b.writeOps - a.writeOps);
        const store = Number(b.storeInstructions - a.storeInstructions);
        phases[name] = { perMessage: Math.round(ins / msgs), perOp: Math.round(ins / ops), storePerOp: Math.round(store / ops), ops };
      };
      // Preload so tree depth is realistic for a small shard (not part of any phase).
      for (let i = 0; i < PRELOAD; i += 100) {
        await c.batch(Array.from({ length: 100 }, (_, j): WriteOp => ({ put: { key: key(i + j), value: rec(i + j, 0), cond: { any: null } } })));
      }
      const base = PRELOAD;
      await measure("insert", async () => { for (let i = 0; i < N; i++) await c.put(key(base + i), rec(base + i, 0), { absent: null }); });
      await measure("updateIndexed", async () => { for (let i = 0; i < N; i++) await c.put(key(base + i), rec(base + i, 1)); });
      await measure("updatePayloadOnly", async () => {
        for (let i = 0; i < N; i++) {
          const v = rec(base + i, 1); v[v.length - 1] = 0x42; // same indexed fields, payload differs
          await c.put(key(base + i), v);
        }
      });
      await measure("delete", async () => { for (let i = 0; i < N; i++) await c.delete(key(base + i)); });
      await measure("batch100Insert", async () => {
        for (let b = 0; b < N / 100 * 5; b++) {
          await c.batch(Array.from({ length: 100 }, (_, j): WriteOp => {
            const i = base + N + b * 100 + j;
            return { put: { key: key(i), value: rec(i, 0), cond: { any: null } } };
          }));
        }
      });
      const st = await s.stats();
      assert.equal(st.indexes.length, k);
      results[`ix${k}`] = phases;
    });
  }

  test("report", () => {
    const rows: string[] = [];
    const overhead: Record<string, Record<string, number>> = {};
    for (const phase of Object.keys(results.ix0!)) {
      const b = results.ix0![phase]!.perOp;
      const line = [0, 1, 2, 3].map((k) => results[`ix${k}`]![phase]!.perOp);
      const store = [0, 1, 2, 3].map((k) => results[`ix${k}`]![phase]!.storePerOp);
      overhead[phase] = {};
      for (const k of [1, 2, 3]) overhead[phase]![`ix${k}`] = (line[k]! - b) / b / k;
      rows.push(`${phase.padEnd(18)} ${line.map((x) => String(x).padStart(10)).join(" ")}  | store ${store.map((x) => String(x).padStart(9)).join(" ")}  | per-index overhead, avg over k=1/2/3: ${[1, 2, 3].map((k) => (100 * overhead[phase]![`ix${k}`]!).toFixed(1) + "%").join(" / ")}`);
    }
    console.log(`\nPocketIC measurement (not mainnet): instructions per op (whole message | inside Store.write), preload=${PRELOAD}, N=${N}\n${"phase".padEnd(18)} ${["ix0", "ix1", "ix2", "ix3"].map((x) => x.padStart(10)).join(" ")}\n${rows.join("\n")}\n`);
    writeFileSync(out, JSON.stringify({ note: "PocketIC measurement, not mainnet", preload: PRELOAD, n: N, results, overheadPerIndex: overhead }, null, 2));
    for (const k of [0, 1, 2, 3]) assert.ok(results[`ix${k}`]!.insert!.perOp > 0);
  });
});
