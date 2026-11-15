import { describe, test } from "node:test";
import assert from "node:assert/strict";
import { Rng, Zipf, makeItem, record, userKey } from "../bench/gen.ts";
import { decodeItem } from "../integration/demo.ts";
import * as E from "../src/encode.ts";

describe("bench generators", () => {
  test("Rng is deterministic and roughly uniform", () => {
    const a = new Rng(42), b = new Rng(42);
    const xs = Array.from({ length: 1000 }, () => a.next());
    assert.deepEqual(xs, Array.from({ length: 1000 }, () => b.next()));
    const mean = xs.reduce((s, x) => s + x, 0) / xs.length;
    assert.ok(Math.abs(mean - 0.5) < 0.05);
    assert.ok(xs.every((x) => x >= 0 && x < 1));
  });
  test("Zipf is skewed toward item 0 and stays in range", () => {
    const z = new Zipf(10_000, new Rng(7));
    const counts = new Map<number, number>();
    for (let i = 0; i < 20_000; i++) { const x = z.next(); assert.ok(x >= 0 && x < 10_000); counts.set(x, (counts.get(x) ?? 0) + 1); }
    const top = counts.get(0) ?? 0;
    assert.ok(top > 20_000 * 0.05, `item 0 drawn ${top} times`);
    assert.ok((counts.get(0) ?? 0) > (counts.get(100) ?? 0));
    const s = new Zipf(1000, new Rng(7));
    for (let i = 0; i < 1000; i++) { const x = s.scrambled(); assert.ok(x >= 0 && x < 1000); }
  });
  test("records are ~1 KB, deterministic, decodable", () => {
    const r = record(5, 1);
    assert.ok(r.length > 1000 && r.length < 1100, `size ${r.length}`);
    assert.deepEqual(r, record(5, 1));
    assert.notDeepEqual(r, record(5, 2));
    assert.equal(decodeItem(r).name, makeItem(5, 1).name);
    assert.equal(E.toHex(userKey(3).pk), E.toHex(E.tuple(E.text("user"), E.nat64(3n))));
  });
});
