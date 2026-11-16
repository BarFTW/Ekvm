// Synthetic, seeded data and key generators for the benchmark suite
// (DESIGN.md §12). Deterministic for a given seed; no I/O.
import * as E from "../src/encode.ts";
import type { Key } from "../src/index.ts";
import { encodeItem, type Item } from "../integration/demo.ts";

/** SplitMix64-derived PRNG returning floats in [0, 1). */
export class Rng {
  private s: bigint;
  constructor(seed: number | bigint) { this.s = BigInt.asUintN(64, BigInt(seed)); }
  nextU64(): bigint {
    this.s = BigInt.asUintN(64, this.s + 0x9e3779b97f4a7c15n);
    let z = this.s;
    z = BigInt.asUintN(64, (z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n);
    z = BigInt.asUintN(64, (z ^ (z >> 27n)) * 0x94d049bb133111ebn);
    return z ^ (z >> 31n);
  }
  next(): number { return Number(this.nextU64() >> 11n) / 2 ** 53; }
  int(n: number): number { return Math.floor(this.next() * n); }
}

/**
 * YCSB Zipfian generator over [0, n) (Gray et al., "Quickly generating
 * billion-record synthetic databases"), theta = 0.99 by default. Item 0 is
 * the most popular; `scrambled` spreads popular items over the key space
 * with an FNV-1a hash, as YCSB's ScrambledZipfianGenerator does.
 */
export class Zipf {
  readonly n: number;
  private readonly theta: number;
  private readonly alpha: number;
  private readonly zetan: number;
  private readonly eta: number;
  private readonly rng: Rng;
  constructor(n: number, rng: Rng, theta = 0.99) {
    this.n = n;
    this.rng = rng;
    this.theta = theta;
    let z = 0;
    for (let i = 1; i <= n; i++) z += 1 / i ** theta;
    this.zetan = z;
    const zeta2 = 1 + 1 / 2 ** theta;
    this.alpha = 1 / (1 - theta);
    this.eta = (1 - (2 / n) ** (1 - theta)) / (1 - zeta2 / z);
  }
  next(): number {
    const u = this.rng.next();
    const uz = u * this.zetan;
    if (uz < 1) return 0;
    if (uz < 1 + 0.5 ** this.theta) return Math.min(1, this.n - 1);
    return Math.min(this.n - 1, Math.floor(this.n * (this.eta * u - this.eta + 1) ** this.alpha));
  }
  scrambled(): number { return fnv1a(this.next()) % this.n; }
}

export function fnv1a(x: number): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < 8; i++) { h ^= Math.floor(x / 256 ** i) & 0xff; h = Math.imul(h, 0x01000193) >>> 0; }
  return h;
}

export const CATEGORIES = ["books", "games", "tools", "toys", "food", "music", "garden", "sport"];

/** ~1 KB Candid `Item` record (D7): fields derived from (id, version, seed). */
export function makeItem(id: number, version: number, opts: { payload?: number; price?: bigint; category?: string } = {}): Item {
  const r = new Rng(BigInt(id) * 1_000_003n + BigInt(version));
  const payload = new Uint8Array(opts.payload ?? 950);
  for (let i = 0; i < payload.length; i += 8) payload[i] = r.int(256);
  return {
    name: `name-${String(r.int(10_000_000)).padStart(7, "0")}`,
    category: opts.category ?? CATEGORIES[r.int(CATEGORIES.length)]!,
    price: opts.price ?? BigInt(r.int(1_000_000)),
    payload,
  };
}
export const record = (id: number, version: number, opts?: Parameters<typeof makeItem>[2]) => encodeItem(makeItem(id, version, opts));

/** YCSB-style "user<id>" keys: one record per partition. */
export const userKey = (id: number): Key => ({ pk: E.tuple(E.text("user"), E.nat64(BigInt(id))), sk: E.text("r") });
/** Time-series keys for YCSB-D: 64 feeds, monotonic sort key. */
export const feedKey = (seq: number): Key => ({ pk: E.tuple(E.text("feed"), E.nat64(BigInt(seq % 64))), sk: E.nat64(BigInt(seq)) });
/** Partitioned keys for YCSB-E: P partitions with many sort keys each. */
export const partKey = (p: number, sk: number): Key => ({ pk: E.tuple(E.text("part"), E.nat64(BigInt(p))), sk: E.nat64(BigInt(sk)) });
