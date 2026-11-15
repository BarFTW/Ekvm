// Client-side cached shard map and routing (DESIGN.md §4.2).
import { slotOfKey } from "./hash.ts";

export type Range = readonly [firstSlot: number, shardIndex: number];

export interface ShardMap<P = string> {
  epoch: bigint;
  slotBits: number;
  shards: readonly P[];
  ranges: readonly Range[];
  schemaVersion: bigint;
}

export const slotCount = (slotBits: number): number => 2 ** slotBits;

export const validate = (m: ShardMap<unknown>): string | null => {
  if (m.slotBits < 1 || m.slotBits > 32) return "slotBits out of range";
  if (m.ranges.length === 0) return "no ranges";
  if (m.ranges[0]![0] !== 0) return "first range must start at slot 0";
  const total = slotCount(m.slotBits);
  let prev = -1;
  for (const [f, s] of m.ranges) {
    if (f >= total) return "range start outside slot space";
    if (f <= prev) return "ranges not strictly increasing";
    if (s >= m.shards.length) return "shard index out of range";
    prev = f;
  }
  return null;
};

/** Binary search: index of the range containing `slot`. O(log R). */
export const rangeIndex = (m: ShardMap<unknown>, slot: number): number => {
  let lo = 0, hi = m.ranges.length;
  while (lo + 1 < hi) {
    const mid = (lo + hi) >>> 1;
    if (m.ranges[mid]![0] <= slot) lo = mid; else hi = mid;
  }
  return lo;
};

export const shardIndexOfSlot = (m: ShardMap<unknown>, slot: number): number => m.ranges[rangeIndex(m, slot)]![1];

export const shardForKey = <P>(m: ShardMap<P>, pk: Uint8Array): P => m.shards[shardIndexOfSlot(m, slotOfKey(pk, m.slotBits))]!;

export const even = <P>(shards: readonly P[], slotBits: number, epoch: bigint): ShardMap<P> => {
  const total = BigInt(slotCount(slotBits)), n = BigInt(shards.length);
  return {
    epoch, slotBits, shards, schemaVersion: 0n,
    ranges: shards.map((_, i) => [Number((BigInt(i) * total) / n), i] as const),
  };
};

/** Slot doubling: slotBits+1, range starts double, owners unchanged, epoch+1. */
export const double = <P>(m: ShardMap<P>): ShardMap<P> => {
  if (m.slotBits >= 32) throw new RangeError("slotBits already 32");
  return { ...m, epoch: m.epoch + 1n, slotBits: m.slotBits + 1, ranges: m.ranges.map(([f, s]) => [f * 2, s] as const) };
};

/** Wire route attached to every shard request. */
export const route = (m: ShardMap<unknown>) => ({ epoch: m.epoch, slotBits: m.slotBits });

/** Merge adjacent ranges with the same owner. */
export const canonical = <P>(m: ShardMap<P>): ShardMap<P> => {
  const out: Range[] = [];
  for (const r of m.ranges) if (out.length === 0 || out[out.length - 1]![1] !== r[1]) out.push(r);
  return { ...m, ranges: out };
};

/** Reassign slots [start, end) to shard table entry `shard`; epoch+1, canonical (same as ShardMap.move). */
export const move = <P>(m: ShardMap<P>, start: number, end: number, shard: number): ShardMap<P> => {
  const total = slotCount(m.slotBits);
  if (!(start < end && end <= total && shard < m.shards.length)) throw new RangeError("invalid move");
  const out: Range[] = [];
  const push = (r: Range) => {
    if (out.length && out[out.length - 1]![0] === r[0]) out.pop();
    out.push(r);
  };
  let placed = false;
  m.ranges.forEach(([a, s], i) => {
    const b = i + 1 < m.ranges.length ? m.ranges[i + 1]![0] : total;
    if (a < start) push([a, s]);
    if (!placed && b > start) { push([start, shard]); placed = true; }
    if (b > end) push([Math.max(a, end), s]);
  });
  return canonical({ ...m, epoch: m.epoch + 1n, ranges: out });
};

/** A logged map change, as returned by `shardMapSince` (Candid variant shape). */
export type MapChange<P = string> =
  | { double: null }
  | { move: { start: bigint; end: bigint; shard: number } }
  | { addShard: P };

export const applyChange = <P>(m: ShardMap<P>, c: MapChange<P>): ShardMap<P> => {
  if ("double" in c) return double(m);
  if ("move" in c) return move(m, Number(c.move.start), Number(c.move.end), c.move.shard);
  return { ...m, epoch: m.epoch + 1n, shards: [...m.shards, c.addShard] };
};

/** Distinct shards that own at least one range. */
export const activeShards = <P>(m: ShardMap<P>): P[] => [...new Set(m.ranges.map(([, s]) => s))].sort((a, b) => a - b).map((i) => m.shards[i]!);
