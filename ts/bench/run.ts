// CLI: node bench/run.ts [smoke|baseline]. Starts a local PocketIC server,
// runs the suite, writes build/bench-m3-<scale>.{json,md}. Local only.
import { writeFileSync } from "node:fs";
import { PocketIc, PocketIcServer, SubnetStateType, createIdentity } from "@dfinity/pic";
import { SCALES, markdown, runSuite } from "./harness.ts";

const scale = SCALES[process.argv[2] ?? "smoke"];
if (!scale) throw new Error(`unknown scale; use one of ${Object.keys(SCALES).join(", ")}`);
const build = (f: string) => new URL(`../../build/${f}`, import.meta.url).pathname;
const server = await PocketIcServer.start({ binPath: process.env.POCKET_IC_BIN, showRuntimeLogs: false });
const pic = await PocketIc.create(server.getUrl(), { application: [{ state: { type: SubnetStateType.New } }] });
const t0 = Date.now();
try {
  const r = await runSuite(pic, createIdentity("ekvm-bench-admin"), createIdentity("ekvm-bench-writer"), build("index-ix3.wasm"), scale, console.log);
  const wall = Math.round((Date.now() - t0) / 1000);
  writeFileSync(build(`bench-m3-${scale.name}.json`), JSON.stringify({ ...r, harnessWallSeconds: wall }, null, 2));
  writeFileSync(build(`bench-m3-${scale.name}.md`), markdown(r) + "\n");
  console.log(`\n${r.note}; scale=${scale.name}; wall ${wall}s; failures: ${r.failures.length}`);
  for (const f of r.failures) console.log("  FAIL " + f);
  if (r.failures.length) process.exitCode = 1;
} finally {
  await pic.tearDown();
  await server.stop();
}
