// Ekvm benchmark harness (DESIGN.md §12, M3): YCSB A–E and IX-1…3 on
// PocketIC. Everything runs locally against simulated cycles; numbers are
// PocketIC measurements at the scale given in the config, nothing more.
//
// Measurement sources:
//  - update instructions: each shard's own counter at the end of `write`
//    (stats.writeInstructions), summed over shards;
//  - read instructions: the shard's `explain` query re-runs each sampled read
//    on the same state and returns its instruction counter;
//  - cycles: change of the shards' PocketIC cycle balances over a phase,
//    divided by update ops (queries are free; idle burn over the phase's
//    simulated time is included and is small at these durations);
//  - messages: calls the client made to shard canisters (counted by proxy);
//  - rows fetched vs returned: the client's global-query stats.
import type { PocketIc } from "@dfinity/pic";
import { Principal } from "@icp-sdk/core/principal";
import type { Identity } from "@icp-sdk/core/agent";
import { indexIdl, shardIdl } from "../src/idl.ts";
import * as E from "../src/encode.ts";
import { EkvmClient, compareRows, excl, incl, type IxRow, type Key, type ShardActor, type WriteOp } from "../src/index.ts";
import { IX, encodeItem } from "../integration/demo.ts";
import { Rng, Zipf, makeItem, feedKey, partKey, userKey, CATEGORIES } from "./gen.ts";

export type Layout = "btree" | "prefix";

export type Scale = {
  name: string;
  seed: number;
  ycsb: { shards: number; records: number; feeds: number; parts: number; perPart: number; ops: number };
  ix1: { ladder: number[]; perShard: number; queries: number };
  ix2: { perShard: number; ops: number; layouts: Layout[] };
  ix3: { shards: number; perShard: number; distinct: number };
};

export const SCALES: Record<string, Scale> = {
  smoke: {
    name: "smoke", seed: 1,
    ycsb: { shards: 2, records: 400, feeds: 100, parts: 4, perPart: 50, ops: 60 },
    ix1: { ladder: [1, 2, 4], perShard: 100, queries: 2 },
    ix2: { perShard: 300, ops: 30, layouts: ["btree", "prefix"] },
    ix3: { shards: 2, perShard: 150, distinct: 8 },
  },
  baseline: {
    name: "baseline", seed: 1,
    ycsb: { shards: 4, records: 100_000, feeds: 10_000, parts: 100, perPart: 100, ops: 1_000 },
    ix1: { ladder: [1, 2, 4, 8, 16, 32], perShard: 2_000, queries: 5 },
    ix2: { perShard: 20_000, ops: 1_000, layouts: ["btree", "prefix"] },
    ix3: { shards: 4, perShard: 5_000, distinct: 16 },
  },
};

const T = 1_000_000_000_000n;
const CYCLES_PER_SHARD = 5n * T;

export type Counter = { calls: Record<string, number>; readInstr: number; readSamples: number; sample: number; seq: number };

export type Cluster = {
  index: any;
  indexId: Principal;
  shards: Principal[];
  client: EkvmClient;
  counter: Counter;
  /** Observed creation fee per shard (attached cycles minus starting balance). */
  creationFee: bigint;
};

export type Phase = {
  workload: string;
  shards: number;
  records: number;
  ops: number;
  mix: Record<string, number>;
  msgsPerOp: number;
  writeOps: number;
  writeInstrPerOp: number | null;
  writeCyclesPerOp: number | null;
  readSamples: number;
  /** Mean instructions of one shard read call (sampled via explain). */
  readInstrPerCall: number | null;
  /** readInstrPerCall × shard read calls per op (e.g. all shards of a global query). */
  readInstrPerOp: number | null;
  rowsFetched?: number;
  rowsReturned?: number;
  extra?: Record<string, unknown>;
};

const READS = new Set(["get", "scan", "ixScan"]);

/** Proxy that counts shard calls and, for 1 in `sample` reads, asks `explain` for the cost. */
function counted(actor: any, c: Counter): ShardActor {
  return new Proxy(actor, {
    get(t, prop: string) {
      const v = t[prop];
      if (typeof v !== "function" || !["write", "get", "scan", "ixScan"].includes(prop)) return v;
      return async (...args: unknown[]) => {
        c.calls[prop] = (c.calls[prop] ?? 0) + 1;
        const r = await v.apply(t, args);
        if (READS.has(prop) && c.sample > 0 && c.seq++ % c.sample === 0) {
          const ex = await t.explain({ [prop]: args[0] });
          if (ex.ok) { c.readInstr += Number(ex.instructions); c.readSamples++; }
        }
        return r;
      };
    },
  }) as ShardActor;
}

export async function makeCluster(pic: PocketIc, admin: Identity, writer: Identity, wasm: string, n: number, layout?: Layout): Promise<Cluster> {
  const subnets = await pic.getApplicationSubnets();
  const ix = await pic.setupCanister({ idlFactory: indexIdl, wasm, sender: admin.getPrincipal(), targetSubnetId: subnets[0]!.id, cycles: 10_000n * T });
  const index: any = ix.actor;
  index.setIdentity(admin);
  const slotBits = Math.max(8, Math.ceil(Math.log2(n)) + 4);
  const shards: Principal[] = await index.createShards(BigInt(n), slotBits, { cyclesPerShard: CYCLES_PER_SHARD, ixLayout: layout ? [{ [layout]: null }] : [] });
  await index.addWriter(writer.getPrincipal());
  const creationFee = CYCLES_PER_SHARD - BigInt(await pic.getCyclesBalance(shards[0]!));
  const counter: Counter = { calls: {}, readInstr: 0, readSamples: 0, sample: 0, seq: 0 };
  const client = new EkvmClient({
    index,
    shard: (cid) => { const a: any = pic.createActor({ idlFactory: shardIdl, canisterId: Principal.fromText(cid) }); a.setIdentity(writer); return counted(a, counter); },
  });
  await client.refresh();
  return { index, indexId: ix.canisterId, shards, client, counter, creationFee };
}

async function snapshot(pic: PocketIc, cl: Cluster) {
  let instr = 0n, ops = 0n, cycles = 0n, entries = 0n, heap = 0n, live = 0n;
  for (const p of cl.shards) {
    const s: any = pic.createActor({ idlFactory: shardIdl, canisterId: p });
    const st = await s.stats();
    instr += BigInt(st.writeInstructions); ops += BigInt(st.writeOps); entries += BigInt(st.entries); heap += BigInt(st.heapBytes); live += BigInt(st.maxLiveBytes);
    cycles += BigInt(await pic.getCyclesBalance(p));
  }
  return { instr, ops, cycles, entries, heap, live };
}

/** Load `ops` in client batches of `size` (split per shard by the client). */
export async function load(cl: Cluster, ops: WriteOp[], size = 400) {
  for (let i = 0; i < ops.length; i += size) {
    const r = await cl.client.batch(ops.slice(i, i + size));
    if (r.some((x) => "err" in x)) throw new Error("load failed");
  }
}

const put = (key: Key, value: Uint8Array): WriteOp => ({ put: { key, value, cond: { any: null } } });

/** Run `body` as one measured phase. `sample` = measure 1 in n reads via explain. */
export async function phase(
  pic: PocketIc, cl: Cluster, workload: string, records: number, sample: number,
  body: () => Promise<{ ops: number; mix: Record<string, number>; rowsFetched?: number; rowsReturned?: number; extra?: Record<string, unknown> }>,
): Promise<Phase> {
  const c = cl.counter;
  c.calls = {}; c.readInstr = 0; c.readSamples = 0; c.sample = sample; c.seq = 0;
  const a = await snapshot(pic, cl);
  const r = await body();
  c.sample = 0;
  const b = await snapshot(pic, cl);
  const writeOps = Number(b.ops - a.ops);
  const msgs = Object.values(c.calls).reduce((s, x) => s + x, 0);
  const readCalls = (c.calls.get ?? 0) + (c.calls.scan ?? 0) + (c.calls.ixScan ?? 0);
  const perCall = c.readSamples ? c.readInstr / c.readSamples : null;
  return {
    workload, shards: cl.shards.length, records, ops: r.ops, mix: r.mix,
    msgsPerOp: round2(msgs / r.ops),
    writeOps,
    writeInstrPerOp: writeOps ? Math.round(Number(b.instr - a.instr) / writeOps) : null,
    writeCyclesPerOp: writeOps ? Math.round(Number(a.cycles - b.cycles) / writeOps) : null,
    readSamples: c.readSamples,
    readInstrPerCall: perCall === null ? null : Math.round(perCall),
    readInstrPerOp: perCall === null ? null : Math.round((perCall * readCalls) / r.ops),
    rowsFetched: r.rowsFetched, rowsReturned: r.rowsReturned, extra: r.extra,
  };
}

const round2 = (x: number) => Math.round(x * 100) / 100;

/** Payload-only update: same indexed fields as version 0, new payload bytes. */
const payloadUpdate = (id: number, v: number) => encodeItem({ ...makeItem(id, 0), payload: makeItem(id, v).payload });

// ------------------------------------------------------------------ YCSB

export async function ycsb(pic: PocketIc, cl: Cluster, s: Scale, check: (cond: boolean, msg: string) => void): Promise<Phase[]> {
  const y = s.ycsb;
  const rng = new Rng(s.seed);
  const zipf = new Zipf(y.records, rng);
  const out: Phase[] = [];
  // Load: user records, feeds (D) and partitions (E).
  const all: WriteOp[] = [];
  for (let i = 0; i < y.records; i++) all.push(put(userKey(i), encodeItem(makeItem(i, 0))));
  for (let i = 0; i < y.feeds; i++) all.push(put(feedKey(i), encodeItem(makeItem(1e9 + i, 0))));
  for (let p = 0; p < y.parts; p++) for (let k = 0; k < y.perPart; k++) all.push(put(partKey(p, k), encodeItem(makeItem(2e9 + p * 1e5 + k, 0))));
  const total = all.length;
  const lp = await phase(pic, cl, "load", total, 0, async () => { await load(cl, all); return { ops: total, mix: { insert: 1 } }; });
  const ls = await snapshot(pic, cl);
  lp.extra = { heapBytesPerRecord: Math.round(Number(ls.heap) / total), maxLiveBytesPerRecord: Math.round(Number(ls.live) / total) };
  out.push(lp);
  let v = 1;
  const readOrUpdate = (name: string, readFrac: number) => phase(pic, cl, name, total, 5, async () => {
    let reads = 0, updates = 0;
    for (let i = 0; i < y.ops; i++) {
      const id = zipf.scrambled();
      if (rng.next() < readFrac) {
        const e = await cl.client.getOne(userKey(id));
        check(e !== null, `${name}: user ${id} readable`);
        reads++;
      } else {
        await cl.client.put(userKey(id), payloadUpdate(id, v++));
        updates++;
      }
    }
    return { ops: y.ops, mix: { read: reads / y.ops, update: updates / y.ops } };
  });
  out.push(await readOrUpdate("YCSB-A", 0.5));
  out.push(await readOrUpdate("YCSB-B", 0.95));
  out.push(await readOrUpdate("YCSB-C", 1.0));
  // D: insert 5% at the head of the feed sequence, read the latest 95%.
  let seq = y.feeds;
  const recent = new Zipf(y.feeds, rng);
  out.push(await phase(pic, cl, "YCSB-D", total, 5, async () => {
    let reads = 0, inserts = 0;
    for (let i = 0; i < y.ops; i++) {
      if (rng.next() < 0.05) { await cl.client.put(feedKey(seq), encodeItem(makeItem(1e9 + seq, 0)), { absent: null }); seq++; inserts++; }
      else {
        const k = seq - 1 - recent.next();
        const e = await cl.client.getOne(feedKey(k));
        check(e !== null, `YCSB-D: feed ${k} readable`);
        reads++;
      }
    }
    return { ops: y.ops, mix: { read: reads / y.ops, insert: inserts / y.ops } };
  }));
  // E: short scans within a partition (1..100 rows), 5% inserts at the partition end.
  const partZ = new Zipf(y.parts, rng);
  const next = Array.from({ length: y.parts }, () => y.perPart);
  out.push(await phase(pic, cl, "YCSB-E", total, 5, async () => {
    let scans = 0, inserts = 0, rows = 0;
    for (let i = 0; i < y.ops; i++) {
      const p = partZ.scrambled();
      if (rng.next() < 0.05) { await cl.client.put(partKey(p, next[p]!), encodeItem(makeItem(2e9 + p * 1e5 + next[p]!, 0))); next[p]!++; inserts++; }
      else {
        const start = rng.int(y.perPart), len = 1 + rng.int(100);
        const r = await cl.client.scan(partKey(p, 0).pk, { from: incl(E.nat64(BigInt(start))), limit: len });
        check(r.entries.length === Math.min(len, next[p]! - start), `YCSB-E: scan length`);
        rows += r.entries.length;
        scans++;
      }
    }
    return { ops: y.ops, mix: { scan: scans / y.ops, insert: inserts / y.ops }, extra: { avgScanRows: round2(rows / Math.max(1, scans)) } };
  }));
  return out;
}

// ------------------------------------------------------------------ IX-1

export async function ix1(pic: PocketIc, mk: (n: number) => Promise<Cluster>, s: Scale, check: (c: boolean, m: string) => void): Promise<Phase[]> {
  const out: Phase[] = [];
  for (const S of s.ix1.ladder) {
    const cl = await mk(S);
    const n = S * s.ix1.perShard;
    const prices: { key: Key; price: bigint }[] = [];
    const ops: WriteOp[] = [];
    for (let i = 0; i < n; i++) { const it = makeItem(i, 0); prices.push({ key: userKey(i), price: it.price }); ops.push(put(userKey(i), encodeItem(it))); }
    await load(cl, ops);
    const ref = prices.map((p) => ({ ixKey: E.nat64(p.price), key: p.key })).sort(compareRows);
    const rng = new Rng(s.seed + S);
    const hex = (rs: { ixKey: Uint8Array; key: Key }[]) => rs.map((r) => E.toHex(r.ixKey) + E.toHex(r.key.pk));
    for (const mode of ["exact", "adaptive"] as const) {
      out.push(await phase(pic, cl, `IX-1 topN100 ${mode}`, n, 1, async () => {
        let fetched = 0, returned = 0, rounds = 0;
        for (let q = 0; q < s.ix1.queries; q++) {
          const p = await cl.client.query(IX.byPrice, { limit: 100, reverse: true, perShard: mode === "adaptive" ? "adaptive" : undefined });
          check(hex(p.rows).join() === hex(ref.slice(-100).reverse()).join(), `IX-1 topN S=${S} ${mode} matches reference`);
          fetched += p.stats.rowsFetched; returned += p.rows.length; rounds += p.stats.rounds;
        }
        return { ops: s.ix1.queries, mix: { topN: 1 }, rowsFetched: fetched, rowsReturned: returned, extra: { roundsPerQuery: round2(rounds / s.ix1.queries) } };
      }));
    }
    out.push(await phase(pic, cl, "IX-1 range page", n, 1, async () => {
      let fetched = 0, returned = 0;
      for (let q = 0; q < s.ix1.queries; q++) {
        const lo = BigInt(rng.int(900_000)), hi = lo + 100_000n; // ~10% of the value range
        const p = await cl.client.query(IX.byPrice, { from: incl(E.nat64(lo)), to: excl(E.nat64(hi)), limit: 100 });
        const exp = ref.filter((r) => { const v = E.toHex(r.ixKey); return v >= E.toHex(E.nat64(lo)) && v < E.toHex(E.nat64(hi)); }).slice(0, 100);
        check(hex(p.rows).join() === hex(exp).join(), `IX-1 range S=${S} matches reference`);
        fetched += p.stats.rowsFetched; returned += p.rows.length;
      }
      return { ops: s.ix1.queries, mix: { range: 1 }, rowsFetched: fetched, rowsReturned: returned };
    }));
  }
  return out;
}

// ------------------------------------------------------------------ IX-2

/** Index-key churn on one shard per layout: payload-only updates vs updates that change the price. */
export async function ix2(pic: PocketIc, mk: (n: number, layout: Layout) => Promise<Cluster>, s: Scale): Promise<Phase[]> {
  const out: Phase[] = [];
  for (const layout of s.ix2.layouts) {
    const cl = await mk(1, layout);
    const n = s.ix2.perShard;
    const ops: WriteOp[] = [];
    for (let i = 0; i < n; i++) ops.push(put(userKey(i), encodeItem(makeItem(i, 0))));
    await load(cl, ops);
    const rng = new Rng(s.seed + 99);
    const zipf = new Zipf(n, rng);
    let v = 1;
    const base = await phase(pic, cl, `IX-2 payload-only update [${layout}]`, n, 0, async () => {
      for (let i = 0; i < s.ix2.ops; i++) { const id = zipf.scrambled(); await cl.client.put(userKey(id), payloadUpdate(id, v++)); }
      return { ops: s.ix2.ops, mix: { update: 1 }, extra: { changedIndexKeysPerOp: 0 } };
    });
    // New price (category and name unchanged): by_price and by_category_price change, by_name does not.
    const churn = await phase(pic, cl, `IX-2 price update [${layout}]`, n, 0, async () => {
      for (let i = 0; i < s.ix2.ops; i++) {
        const id = zipf.scrambled();
        await cl.client.put(userKey(id), encodeItem({ ...makeItem(id, 0), price: BigInt(rng.int(1_000_000)), payload: makeItem(id, v++).payload }));
      }
      return { ops: s.ix2.ops, mix: { update: 1 }, extra: { changedIndexKeysPerOp: 2 } };
    });
    churn.extra = { ...churn.extra, instrPerChangedKey: Math.round(((churn.writeInstrPerOp ?? 0) - (base.writeInstrPerOp ?? 0)) / 2) };
    const st = await snapshot(pic, cl);
    churn.extra.heapBytesPerRecord = Math.round(Number(st.heap) / n);
    churn.extra.maxLiveBytesPerRecord = Math.round(Number(st.live) / n);
    out.push(base, churn);
  }
  return out;
}

// ------------------------------------------------------------------ IX-3

/** Few distinct, Zipf-distributed index values: long tie ranges paged with cursors. */
export async function ix3(pic: PocketIc, cl: Cluster, s: Scale, check: (c: boolean, m: string) => void): Promise<Phase[]> {
  const n = s.ix3.shards * s.ix3.perShard;
  const rng = new Rng(s.seed + 3);
  const pz = new Zipf(s.ix3.distinct, rng), cz = new Zipf(CATEGORIES.length, rng);
  const rows: { key: Key; price: bigint; category: string }[] = [];
  const ops: WriteOp[] = [];
  for (let i = 0; i < n; i++) {
    const price = BigInt(pz.next() * 1000), category = CATEGORIES[cz.next()]!;
    rows.push({ key: userKey(i), price, category });
    ops.push(put(userKey(i), encodeItem(makeItem(i, 0, { price, category, payload: 200 }))));
  }
  await load(cl, ops);
  const out: Phase[] = [];
  const pageAll = async (name: string, ix: number, prefix: Uint8Array, expected: { ixKey: Uint8Array; key: Key }[]) =>
    phase(pic, cl, name, n, 1, async () => {
      const got: IxRow[] = [];
      let cursor: string | null = null, pages = 0, fetched = 0;
      do {
        const p: Awaited<ReturnType<EkvmClient["query"]>> = await cl.client.query(ix, { from: incl(prefix), to: incl(prefix), limit: 100, cursor });
        got.push(...p.rows); cursor = p.cursor; pages++; fetched += p.stats.rowsFetched;
      } while (cursor);
      const h = (r: { ixKey: Uint8Array; key: Key }) => E.toHex(r.ixKey) + "/" + E.toHex(r.key.pk);
      check(got.length === expected.length && got.every((r, i) => h(r) === h(expected[i]!)), `${name}: all ${expected.length} tied rows, in order, no duplicates`);
      return { ops: pages, mix: { page: 1 }, rowsFetched: fetched, rowsReturned: got.length, extra: { pages, matching: expected.length } };
    });
  const hot = rows.filter((r) => r.price === 0n).map((r) => ({ ixKey: E.nat64(0n), key: r.key })).sort(compareRows);
  out.push(await pageAll("IX-3 hottest price value", IX.byPrice, E.nat64(0n), hot));
  const cat = CATEGORIES[0]!;
  const hotCat = rows.filter((r) => r.category === cat)
    .map((r) => ({ ixKey: E.tuple(E.text(cat), E.desc(E.nat64(r.price))), key: r.key })).sort(compareRows);
  out.push(await pageAll("IX-3 hottest category (by_category_price)", IX.byCategoryPrice, E.tuple(E.text(cat)), hotCat));
  return out;
}

// ------------------------------------------------------------------ suite

export type SuiteResult = {
  note: string;
  scale: Scale;
  creationFeePerShard: string;
  phases: Phase[];
  failures: string[];
};

/** Run every workload at `s`; each workload gets its own index + shards (created via `createShards`). */
export async function runSuite(pic: PocketIc, admin: Identity, writer: Identity, indexWasm: string, s: Scale, log: (m: string) => void = () => {}): Promise<SuiteResult> {
  const failures: string[] = [];
  const check = (c: boolean, m: string) => { if (!c && failures.length < 50) failures.push(m); };
  const mk = (n: number, layout?: Layout) => makeCluster(pic, admin, writer, indexWasm, n, layout);
  const phases: Phase[] = [];
  const add = (ps: Phase[]) => { for (const p of ps) { phases.push(p); log(fmt(p)); } };
  const yc = await mk(s.ycsb.shards);
  add(await ycsb(pic, yc, s, check));
  add(await ix1(pic, (n) => mk(n), s, check));
  add(await ix2(pic, (n, l) => mk(n, l), s));
  add(await ix3(pic, await mk(s.ix3.shards), s, check));
  return {
    note: "PocketIC measurement (local replica emulation, simulated cycles), not mainnet",
    scale: s, creationFeePerShard: yc.creationFee.toString(), phases, failures,
  };
}

const num = (x: number | null | undefined) => (x === null || x === undefined ? "–" : x.toLocaleString("en-US"));

export function fmt(p: Phase): string {
  const rows = p.rowsFetched !== undefined ? ` rows ${p.rowsFetched}/${p.rowsReturned}` : "";
  return `${p.workload.padEnd(44)} S=${String(p.shards).padStart(2)} n=${String(p.records).padStart(6)} ops=${String(p.ops).padStart(5)} msgs/op=${p.msgsPerOp} ` +
    `write ins/op=${num(p.writeInstrPerOp)} cyc/op=${num(p.writeCyclesPerOp)} read ins/op=${num(p.readInstrPerOp)} (/call ${num(p.readInstrPerCall)})${rows}${p.extra ? " " + JSON.stringify(p.extra) : ""}`;
}

export function markdown(r: SuiteResult): string {
  const lines = [
    `| Workload | S | Records | Ops | Mix | Msgs/op | Write instr/op | Write cycles/op | Read instr/op | Read instr/call | Rows fetched / returned | Notes |`,
    `|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---|`,
  ];
  for (const p of r.phases) {
    const mix = Object.entries(p.mix).map(([k, v]) => `${k} ${Math.round(v * 100)}%`).join(", ");
    const rows = p.rowsFetched !== undefined ? `${p.rowsFetched} / ${p.rowsReturned}` : "";
    lines.push(`| ${p.workload} | ${p.shards} | ${p.records.toLocaleString("en-US")} | ${p.ops} | ${mix} | ${p.msgsPerOp} | ${num(p.writeInstrPerOp)} | ${num(p.writeCyclesPerOp)} | ${num(p.readInstrPerOp)} | ${num(p.readInstrPerCall)} | ${rows} | ${p.extra ? Object.entries(p.extra).map(([k, v]) => `${k}=${v}`).join(", ") : ""} |`);
  }
  return lines.join("\n");
}
