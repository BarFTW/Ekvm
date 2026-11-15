# Ekvm key encodings and key hash (spec)

Normative for Motoko (`src/Encode.mo`, `src/Hash.mo`), TypeScript (`ts/src/encode.ts`, `ts/src/hash.ts`) and the independent Python reference (`tools/gen_vectors.py`).

All three implementations are tested against the shared vectors in `test/vectors/vectors.json`, which `test/Vectors.mo` mirrors for Motoko. The vectors are produced by the Python reference, so neither the Motoko nor the TS implementation is its own source of truth.

## Order-preserving encodings

Every encoding is **order-preserving**: unsigned lexicographic byte order equals value order. Every encoding is also **prefix-free**, so encodings can be concatenated into composite keys and complemented for descending order.

| Type | Encoding |
|---|---|
| `nat8/16/32/64` | Big-endian, fixed width |
| `int8/16/32/64` | Two's complement, big-endian, sign bit flipped |
| `nat` (unbounded) | 1 length byte L (0–255), then L bytes of minimal big-endian magnitude. Zero is `00`. Traps or throws above 255 bytes |
| `int` (unbounded) | Zero is `80`. Positive: `80+L` then the magnitude. Negative: `80−L` then the bitwise complement of the magnitude. L ≤ 127 |
| `float` (IEEE-754 binary64) | Take the bits big-endian. If the sign bit is 0, set it. If the sign bit is 1, complement all 64 bits. −0.0 is normalised to +0.0. **NaN is rejected** |
| `bool` | `00` / `01` |
| `bytes` | Each `00` becomes `00 FF`, then the terminator `00 00` |
| `text` | `bytes(UTF-8(text))`. UTF-8 byte order equals code-point order |
| `desc(e)` | Bitwise complement of every byte of `e` (valid because `e` is prefix-free) |
| `tuple(e1, …, en)` | Concatenation |

**Why the two-byte terminator `00 00`:** the escape is `00 FF` and the terminator is `00 00`, so the terminator always sorts before an escaped NUL. That keeps `("a", x) < ("a\0", y)` for any x, y. A one-byte terminator would let the next tuple component's first byte decide the order instead.

**Motoko float note:** moc 2.2.1 and core 2.6.2 have no primitive that reinterprets a Float's bits as an integer. `Encode.float` reads the 8 IEEE bytes out of `to_candid(f)` instead, and the tests pin the expected Candid layout (15 bytes).

## Physical key layout and index range bounds (M1)

- **Primary order** is `(pk, sk)` compared component-wise as unsigned bytes. That equals the byte order of `bytes(pk) ‖ sk`, so a partition is contiguous and ordered by raw `sk`.
- **Index order** is `(ixKey, pk, sk)` compared component-wise. That equals the byte order of the physical key `ixKey ‖ bytes(pk) ‖ sk` whenever `ixKey` is prefix-free, which every encoder above guarantees. Both TS (`physicalIxKey`) and Motoko (`Store.physicalIxKey`) expose this byte form for clients that merge rows as opaque bytes. The shard itself stores the structured form (no concatenation on the write path).
- **`scan` bounds** compare `sk` exactly: `#incl s` ⇒ `sk ≥ s` / `sk ≤ s`, `#excl s` ⇒ `sk > s` / `sk < s`.
- **`ixScan` bounds are prefix bounds** on the encoded index key, so a tuple prefix selects a whole group:
  - lower `#incl b`: `ixKey ≥ b`; lower `#excl b`: `ixKey ≥ succ(b)`, i.e. skip every key with prefix `b`;
  - upper `#incl b`: `ixKey < succ(b)`, i.e. include every key with prefix `b`; upper `#excl b`: `ixKey < b`;
  - `succ(b)` = `b` with trailing `FF` bytes removed and the last byte incremented (none if `b` is empty or all `FF`).
  - Example: `from = to = #incl text("games")` on index `(category, desc(price))` returns exactly the `games` rows, most expensive first.

## Key hash and slot

- **Key hash:** `keyHash(pk) = first 4 bytes of SHA-256(pk)`, read as a big-endian u32.
- **Slot:** `slot(pk, slotBits) = keyHash(pk) >> (32 − slotBits)`, for `1 ≤ slotBits ≤ 32`.
- **Doubling:** `slot(pk, b+1) ∈ {2·slot(pk, b), 2·slot(pk, b)+1}`.

## Regenerating the vectors

```
python3 tools/gen_vectors.py           # rewrite vectors
python3 tools/gen_vectors.py --check   # CI: fail if stale
```
