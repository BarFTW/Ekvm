# Ekvm v2: Elastic Key-Value Map for the Internet Computer

Ekvm is a sharded key-value database library for the Internet Computer, written in Motoko with a TypeScript client. It supports user-defined secondary indexes and global ordered scans. The design is in [docs/DESIGN.md](docs/DESIGN.md) and the key-encoding spec in [docs/ENCODING.md](docs/ENCODING.md).

**Status:** milestone **M0**, the scaffolding. It contains:
- order-preserving encoders in Motoko and TypeScript;
- the 32-bit key hash and slot logic;
- the range-compressed shard map, with slot doubling;
- shard-side route checks;
- skeleton `Index` and `Shard` canisters;
- a PocketIC test harness running on two subnets.

No data operations yet; they arrive in M1.

## Layout

```
src/            Motoko library (Encode, Hash, ShardMap, Routing, Types)
canisters/      Index.mo, Shard.mo (actor classes)
test/           Motoko unit tests (mops test) + generated vectors
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
