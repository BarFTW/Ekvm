// M3 benchmark harness at smoke scale on PocketIC (local only): every
// workload runs end to end and its correctness checks pass. Baseline numbers
// come from `scripts/bench.sh baseline` (docs/BENCH.md), not from this test.
import { after, before, describe, test } from "node:test";
import assert from "node:assert/strict";
import { PocketIc, PocketIcServer, SubnetStateType, createIdentity } from "@dfinity/pic";
import { SCALES, runSuite } from "../bench/harness.ts";

const wasm = (n: string) => new URL(`../../build/${n}.wasm`, import.meta.url).pathname;
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

describe("benchmark harness (smoke scale, PocketIC)", () => {
  test("YCSB A–E and IX-1…3 run and pass their checks", async () => {
    const r = await runSuite(pic, createIdentity("ekvm-h-admin"), createIdentity("ekvm-h-writer"), wasm("index-ix3"), SCALES.smoke!);
    assert.deepEqual(r.failures, []);
    const names = r.phases.map((p) => p.workload);
    for (const w of ["YCSB-A", "YCSB-B", "YCSB-C", "YCSB-D", "YCSB-E", "IX-1 topN100 exact", "IX-1 range page", "IX-2 price update [prefix]", "IX-3 hottest price value"]) {
      assert.ok(names.includes(w), `${w} ran`);
    }
    const a = r.phases.find((p) => p.workload === "YCSB-A")!;
    assert.ok(a.writeInstrPerOp! > 0 && a.writeCyclesPerOp! > 0 && a.readInstrPerOp! > 0);
    assert.equal(r.phases.find((p) => p.workload === "YCSB-C")!.writeOps, 0);
    const ix1 = r.phases.filter((p) => p.workload === "IX-1 topN100 exact");
    assert.deepEqual(ix1.map((p) => p.shards), SCALES.smoke!.ix1.ladder);
    assert.ok(BigInt(r.creationFeePerShard) > 0n);
  });
});
