import { test } from "node:test";
import assert from "node:assert/strict";
import * as E from "../src/encode.ts";
import { keyHash, slotOf } from "../src/hash.ts";
import { even, double, shardForKey } from "../src/shardMap.ts";

// Deterministic PRNG (xorshift64*).
let seed = 0x9e3779b97f4a7c15n;
const rnd = (): bigint => {
  seed ^= seed >> 12n; seed ^= (seed << 25n) & 0xffff_ffff_ffff_ffffn; seed ^= seed >> 27n;
  return (seed * 0x2545f4914f6cdd1dn) & 0xffff_ffff_ffff_ffffn;
};
const sgn = (x: number) => Math.sign(x);
const agrees = <T>(xs: T[], enc: (x: T) => Uint8Array, cmp: (a: T, b: T) => number) => {
  for (const a of xs) for (const b of xs) assert.equal(sgn(E.compareBytes(enc(a), enc(b))), sgn(cmp(a, b)));
};
const big = (a: bigint, b: bigint) => (a < b ? -1 : a > b ? 1 : 0);

test("int64 order", () => agrees(Array.from({ length: 200 }, () => BigInt.asIntN(64, rnd())), E.int64, big));
test("unbounded nat order", () => agrees(Array.from({ length: 200 }, (_, i) => rnd() * (i % 3 ? 1n : 1n << 70n) >> BigInt(i % 60)), E.nat, big));
test("unbounded int order", () =>
  agrees(Array.from({ length: 200 }, (_, i) => (i % 2 ? -1n : 1n) * (rnd() >> BigInt(i % 60))), E.int, big));
test("float order", () =>
  agrees(Array.from({ length: 200 }, (_, i) => Number(BigInt.asIntN(64, rnd())) / 1e9 * (i % 7 ? 1 : 1e300)), E.float, (a, b) => (a < b ? -1 : a > b ? 1 : 0)));
test("text order (UTF-8 byte order) incl. NUL and prefixes", () => {
  const xs = ["", "\0", "a", "a\0", "a\0b", "ab", "b", "é", "א", "😀"];
  agrees(xs, E.text, (a, b) => E.compareBytes(new TextEncoder().encode(a), new TextEncoder().encode(b)));
});
test("desc reverses; tuples order by first component then second", () => {
  const xs = Array.from({ length: 50 }, () => BigInt.asIntN(64, rnd()));
  agrees(xs, (x) => E.desc(E.int64(x)), (a, b) => big(b, a));
  const pairs: [string, bigint][] = [["a", 2n], ["a", 10n], ["a\0", 0n], ["ab", 0n], ["b", 1n]];
  agrees(pairs, ([t, n]) => E.tuple(E.text(t), E.nat64(n)), (p, q) =>
    E.compareBytes(E.text(p[0]), E.text(q[0])) || big(p[1], q[1]));
});
test("int64 decode round-trip", () => {
  for (let i = 0; i < 100; i++) { const x = BigInt.asIntN(64, rnd()); assert.equal(E.decodeInt64(E.int64(x)), x); }
});
test("doubling never moves a key", () => {
  const m = even(["a", "b", "c", "d", "e"], 16, 1n), d = double(m);
  for (let i = 0; i < 2000; i++) {
    const pk = E.nat64(rnd());
    assert.equal(shardForKey(m, pk), shardForKey(d, pk));
    const s = slotOf(keyHash(pk), 16), c = slotOf(keyHash(pk), 17);
    assert.ok(c === 2 * s || c === 2 * s + 1);
  }
});
