// Order-preserving key encodings. Spec: ../../docs/ENCODING.md
// Byte order of the output == natural order of the input. All encodings are
// prefix-free, so they can be concatenated (tuple) and inverted (desc).

export const concat = (...parts: Uint8Array[]): Uint8Array => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
};

const be = (x: bigint, n: number): Uint8Array => {
  const out = new Uint8Array(n);
  for (let i = n - 1; i >= 0; i--) { out[i] = Number(x & 0xffn); x >>= 8n; }
  return out;
};

const natBytes = (x: bigint): Uint8Array => {
  const bs: number[] = [];
  while (x > 0n) { bs.unshift(Number(x & 0xffn)); x >>= 8n; }
  return Uint8Array.from(bs);
};

const checkRange = (x: bigint, lo: bigint, hi: bigint, t: string) => {
  if (x < lo || x > hi) throw new RangeError(`${t}: ${x} out of range`);
};

const natN = (bits: number) => (x: bigint | number): Uint8Array => {
  const v = BigInt(x);
  checkRange(v, 0n, (1n << BigInt(bits)) - 1n, `nat${bits}`);
  return be(v, bits / 8);
};
const intN = (bits: number) => (x: bigint | number): Uint8Array => {
  const v = BigInt(x);
  const B = BigInt(bits);
  checkRange(v, -(1n << (B - 1n)), (1n << (B - 1n)) - 1n, `int${bits}`);
  return be(((v + (1n << B)) % (1n << B)) ^ (1n << (B - 1n)), bits / 8);
};

export const nat8 = natN(8);
export const nat16 = natN(16);
export const nat32 = natN(32);
export const nat64 = natN(64);
export const int8 = intN(8);
export const int16 = intN(16);
export const int32 = intN(32);
export const int64 = intN(64);

/** Unbounded Nat: length byte ‖ minimal big-endian bytes (≤ 255 bytes). */
export const nat = (x: bigint | number): Uint8Array => {
  const v = BigInt(x);
  if (v < 0n) throw new RangeError("nat: negative");
  const b = natBytes(v);
  if (b.length > 255) throw new RangeError("nat: exceeds 255 bytes");
  return concat(Uint8Array.of(b.length), b);
};

/** Unbounded Int: 0x80 for 0; 0x80+len ‖ |x|; 0x80−len ‖ ~|x| (≤ 127 bytes). */
export const int = (x: bigint | number): Uint8Array => {
  const v = BigInt(x);
  if (v === 0n) return Uint8Array.of(0x80);
  const b = natBytes(v < 0n ? -v : v);
  if (b.length > 127) throw new RangeError("int: exceeds 127 bytes");
  return v > 0n ? concat(Uint8Array.of(0x80 + b.length), b) : concat(Uint8Array.of(0x80 - b.length), b.map((c) => c ^ 0xff));
};

/** Float64: positive → set sign bit; negative → complement all bits; −0 → +0; NaN throws. */
export const float = (f: number): Uint8Array => {
  if (Number.isNaN(f)) throw new RangeError("float: NaN is not encodable");
  const dv = new DataView(new ArrayBuffer(8));
  dv.setFloat64(0, f === 0 ? 0 : f);
  let u = dv.getBigUint64(0);
  u = u >> 63n ? u ^ 0xffff_ffff_ffff_ffffn : u | (1n << 63n);
  return be(u, 8);
};

export const bool = (b: boolean): Uint8Array => Uint8Array.of(b ? 1 : 0);

/** Bytes: 0x00 → 0x00 0xFF, terminated by 0x00 0x00. */
export const bytes = (b: Uint8Array): Uint8Array => {
  const out: number[] = [];
  for (const c of b) { out.push(c); if (c === 0) out.push(0xff); }
  out.push(0, 0);
  return Uint8Array.from(out);
};

export const text = (t: string): Uint8Array => bytes(new TextEncoder().encode(t));
export const desc = (b: Uint8Array): Uint8Array => b.map((c) => c ^ 0xff);
export const tuple = (...parts: Uint8Array[]): Uint8Array => concat(...parts);

// ---- decoders (client-side display / debugging) ----

const rdbe = (b: Uint8Array): bigint => b.reduce((x, c) => (x << 8n) | BigInt(c), 0n);

export const decodeNat64 = (b: Uint8Array): bigint => rdbe(b.subarray(0, 8));
export const decodeInt64 = (b: Uint8Array): bigint => BigInt.asIntN(64, rdbe(b.subarray(0, 8)) ^ (1n << 63n));
export const decodeFloat = (b: Uint8Array): number => {
  let u = rdbe(b.subarray(0, 8));
  u = u >> 63n ? u ^ (1n << 63n) : u ^ 0xffff_ffff_ffff_ffffn;
  const dv = new DataView(new ArrayBuffer(8));
  dv.setBigUint64(0, u);
  return dv.getFloat64(0);
};
/** Decode an escaped byte string; returns the value and the number of bytes consumed. */
export const decodeBytes = (b: Uint8Array): { value: Uint8Array; used: number } => {
  const out: number[] = [];
  for (let i = 0; i < b.length; i++) {
    if (b[i] !== 0) { out.push(b[i]!); continue; }
    if (b[i + 1] === 0xff) { out.push(0); i++; continue; }
    if (b[i + 1] === 0) return { value: Uint8Array.from(out), used: i + 2 };
    throw new RangeError("decodeBytes: invalid escape");
  }
  throw new RangeError("decodeBytes: missing terminator");
};
export const decodeText = (b: Uint8Array): { value: string; used: number } => {
  const r = decodeBytes(b);
  return { value: new TextDecoder("utf-8", { fatal: true }).decode(r.value), used: r.used };
};

export const toHex = (b: Uint8Array): string => Array.from(b, (c) => c.toString(16).padStart(2, "0")).join("");
export const fromHex = (h: string): Uint8Array => {
  if (h.length % 2) throw new RangeError("fromHex: odd length");
  return Uint8Array.from({ length: h.length / 2 }, (_, i) => parseInt(h.slice(2 * i, 2 * i + 2), 16));
};

/** Unsigned lexicographic byte comparison (the order Ekvm keys sort in). */
export const compareBytes = (a: Uint8Array, b: Uint8Array): number => {
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) if (a[i] !== b[i]) return a[i]! - b[i]!;
  return a.length - b.length;
};
