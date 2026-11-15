// 32-bit key hash and slot derivation (DESIGN.md §4.1).
import { sha256 } from "@noble/hashes/sha2.js";

/** First 4 bytes of SHA-256(pk), big-endian. */
export const keyHash = (pk: Uint8Array): number => {
  const d = sha256(pk);
  return ((d[0]! << 24) | (d[1]! << 16) | (d[2]! << 8) | d[3]!) >>> 0;
};

/** Top `slotBits` bits of the hash (1..32). */
export const slotOf = (h: number, slotBits: number): number => {
  if (!Number.isInteger(slotBits) || slotBits < 1 || slotBits > 32) throw new RangeError("slotBits must be 1..32");
  return slotBits === 32 ? h >>> 0 : h >>> (32 - slotBits);
};

export const slotOfKey = (pk: Uint8Array, slotBits: number): number => slotOf(keyHash(pk), slotBits);
