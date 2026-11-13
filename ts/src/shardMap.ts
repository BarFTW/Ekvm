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
