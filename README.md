# Ekvm v2: Elastic Key-Value Map for the Internet Computer

Ekvm is a sharded key-value database library for the Internet Computer, written in Motoko with a TypeScript client. It supports user-defined secondary indexes and global ordered scans. The design is in [docs/DESIGN.md](docs/DESIGN.md) and the key-encoding spec in [docs/ENCODING.md](docs/ENCODING.md).

**Status:** milestones **M0–M2** are done.
- M0: order-preserving encoders (Motoko + TS, shared vectors), 32-bit key hash and slots, range-compressed shard map with doubling, shard-side route checks, PocketIC harness on two subnets.
- M1: shard data operations (`write` batches with CAS and dedupe, `get`, `getCertainly`, partition `scan` with cursors and a 1 MiB page cap), writer/reader allowlists pushed by the index, and **local secondary indexes declared in Motoko** (`Schema`), maintained atomically on write and served by `ixScan`.
- M2: multi-shard TS `EkvmClient`: lazily refreshed shard map (delta fetch via `shardMapSince`), key routing, cross-shard `get`/`batch`, and the **global ordered `query`/`topN`** (scatter-gather k-way merge, stateless cursor). Zero-movement slot doubling (`doubleSlots`/`finishDoubling`).

```ts
const client = new EkvmClient({ index: indexActor, shard: (id) => makeShardActor(id) });
await client.batch(ops);                                         // split by shard, atomic per shard
const { rows, cursor } = await client.query(1, { limit: 100 });  // global order over index 1
const next = await client.query(1, { limit: 100, cursor });
```

### Declaring indexes

A shard build compiles in one schema package (moc `--package ekvm-schema <dir>`, see `scripts/build.sh`). Its `Schema.mo` exports:

```motoko
import Encode "mo:ekvm/Encode";   // or a relative path
import S "mo:ekvm/Schema";
module {
  type Item = { name : Text; category : Text; price : Nat64 };
  func decode(v : Blob) : ?Item = from_candid (v);   // runs once per written entry
  public let schema : S.Schema<Item> = {
    version = 1;
    decode;
    indexes = [
      { id = 1; name = "by_price"; extract = func(_, _, i : Item) : ?Blob = ?Encode.nat64(i.price) },
      { id = 2; name = "by_category_price";
        extract = func(_, _, i : Item) : ?Blob = ?Encode.tuple([Encode.text(i.category), Encode.desc(Encode.nat64(i.price))]) },
    ];
  };
};
```

See `test/schemas/Demo.mo` for a complete example (it screens non-Candid values first, because `from_candid` traps on malformed input).

## Layout

```
src/            Motoko library (Encode, Hash, ShardMap, Routing, Types, Schema, Store)
canisters/      Index.mo, Shard.mo (actor classes; Shard imports mo:ekvm-schema/Schema)
schemas/empty/  default shard schema (no indexes)
test/           Motoko unit tests (mops test), generated vectors, test/schemas (demo + 0..3-index bench schemas)
tools/          gen_vectors.py: independent Python reference + vector generator
ts/             TypeScript client (src/), unit tests (test/), PocketIC integration (integration/)
scripts/        build.sh, test-all.sh
```

## Running locally (no network, no cycles)

```
npm i -g ic-mops && mops install && (cd ts && npm install)
scripts/test-all.sh
```

Toolchains are pinned in `mops.toml`: moc, pocket-ic and wasmtime. Nothing here deploys to mainnet.

License: Apache-2.0.
