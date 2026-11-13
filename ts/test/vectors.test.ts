import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as E from "../src/encode.ts";
import { keyHash, slotOf } from "../src/hash.ts";
import { even, double, shardIndexOfSlot, validate } from "../src/shardMap.ts";

const V = JSON.parse(readFileSync(new URL("../../test/vectors/vectors.json", import.meta.url), "utf8"));
const hex = E.toHex;
const fixed: Record<string, (x: bigint) => Uint8Array> = {
  nat8: E.nat8, nat16: E.nat16, nat32: E.nat32, nat64: E.nat64,
  int8: E.int8, int16: E.int16, int32: E.int32, int64: E.int64,
};
const pf = (s: string) => (s === "inf" ? Infinity : s === "-inf" ? -Infinity : Number(s));

test("fixed-width vectors", () => {
  for (const v of [...V.fixedNat, ...V.fixedInt]) assert.equal(hex(fixed[v.type]!(BigInt(v.value))), v.hex, `${v.type} ${v.value}`);
});
test("nat / int vectors", () => {
  for (const v of V.nat) assert.equal(hex(E.nat(BigInt(v.value))), v.hex);
  for (const v of V.int) assert.equal(hex(E.int(BigInt(v.value))), v.hex);
});
test("float vectors and decode round-trip", () => {
  for (const v of V.float) {
    assert.equal(hex(E.float(pf(v.value))), v.hex, v.value);
    assert.equal(E.decodeFloat(E.float(pf(v.value))), pf(v.value) === 0 ? 0 : pf(v.value));
  }
  assert.throws(() => E.float(NaN));
});
test("bool / text / bytes / desc / tuple vectors", () => {
  for (const v of V.bool) assert.equal(hex(E.bool(v.value)), v.hex);
  for (const v of V.text) {
    assert.equal(hex(E.text(v.value)), v.hex, JSON.stringify(v.value));
    assert.equal(E.decodeText(E.text(v.value)).value, v.value);
  }
  for (const v of V.blob) assert.equal(hex(E.bytes(E.fromHex(v.value))), v.hex);
  for (const v of V.desc) {
    const inner = v.of === "text" ? E.text(v.value) : E.int64(BigInt(v.value));
    assert.equal(hex(E.desc(inner)), v.hex);
  }
  const enc = ([t, x]: [string, string]) =>
    t === "text" ? E.text(x) : t === "nat64" ? E.nat64(BigInt(x)) : t === "blob" ? E.bytes(E.fromHex(x)) : E.desc(E.float(Number(x)));
  for (const v of V.tuple) assert.equal(hex(E.tuple(...v.parts.map(enc))), v.hex);
});
test("key hash and slots", () => {
  for (const v of V.hash) {
    const h = keyHash(E.fromHex(v.pk));
    assert.equal(h, v.hash);
    for (const [bits, slot] of Object.entries(v.slots)) assert.equal(slotOf(h, Number(bits)), slot);
  }
});
test("shard map: even split, lookup, doubling", () => {
  for (const v of V.shardMap) {
    const m = even(Array.from({ length: v.shards }, (_, i) => `s${i}`), v.slotBits, 1n);
    assert.equal(validate(m), null);
    assert.deepEqual(m.ranges, v.ranges);
    for (const [slot, idx] of v.lookups) assert.equal(shardIndexOfSlot(m, slot), idx);
    const d = double(m);
    assert.deepEqual(d.ranges, v.doubled);
    for (const [slot, idx] of v.doubledLookups) assert.equal(shardIndexOfSlot(d, slot), idx);
  }
});
