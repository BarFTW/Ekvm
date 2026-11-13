// Candid IDL factories for the Ekvm canisters (mirrors build/shard.did and build/index.did).
import { IDL } from "@icp-sdk/core/candid";

const Bytes = IDL.Vec(IDL.Nat8);
export const Route = IDL.Record({ epoch: IDL.Nat64, slotBits: IDL.Nat8 });
export const Key = IDL.Record({ pk: Bytes, sk: Bytes });
export const Err = IDL.Variant({
  wrongShard: IDL.Record({ epoch: IDL.Nat64, slotBits: IDL.Nat8 }),
  conflict: IDL.Record({ key: Key, current: IDL.Opt(IDL.Nat64) }),
  unauthorized: IDL.Null, tooLarge: IDL.Null, migrating: IDL.Null, unknownIndex: IDL.Null,
});
export const Bound = IDL.Variant({ incl: Bytes, excl: Bytes, unbounded: IDL.Null });
const Cond = IDL.Variant({ any: IDL.Null, absent: IDL.Null, version: IDL.Nat64 });
const WriteOp = IDL.Variant({
  put: IDL.Record({ key: Key, value: Bytes, cond: Cond }),
  delete: IDL.Record({ key: Key, cond: Cond }),
});
const Entry = IDL.Record({ key: Key, value: Bytes, version: IDL.Nat64 });
const Res = (ok: IDL.Type) => IDL.Variant({ ok, err: Err });
const GetReq = IDL.Record({ route: Route, keys: IDL.Vec(Key) });
const ScanReq = IDL.Record({ route: Route, pk: Bytes, from: Bound, to: Bound, limit: IDL.Nat, reverse: IDL.Bool });
export const IxPos = IDL.Record({ ixKey: Bytes, key: Key });
const IxScanReq = IDL.Record({
  route: Route, index: IDL.Nat16, from: Bound, to: Bound, after: IDL.Opt(IxPos),
  limit: IDL.Nat, reverse: IDL.Bool, withValues: IDL.Bool,
});
const IxRow = IDL.Record({ ixKey: Bytes, key: Key, version: IDL.Nat64, value: IDL.Opt(Bytes) });
const Readers = IDL.Variant({ public: IDL.Null, allow: IDL.Vec(IDL.Principal) });
const Access = IDL.Record({ version: IDL.Nat64, writers: IDL.Vec(IDL.Principal), readers: Readers });
const Assignment = IDL.Record({
  epoch: IDL.Nat64, slotBits: IDL.Nat8, acceptPrevSlotBits: IDL.Opt(IDL.Nat8), owned: IDL.Vec(IDL.Tuple(IDL.Nat, IDL.Nat)),
});
const ShardMapT = IDL.Record({
  epoch: IDL.Nat64, slotBits: IDL.Nat8, shards: IDL.Vec(IDL.Principal),
  ranges: IDL.Vec(IDL.Tuple(IDL.Nat32, IDL.Nat16)), schemaVersion: IDL.Nat,
});
const IndexInfo = IDL.Record({ id: IDL.Nat16, name: IDL.Text, ready: IDL.Bool, entries: IDL.Nat });
const Stats = IDL.Record({
  entries: IDL.Nat, bytes: IDL.Nat, lastVersion: IDL.Nat64, schemaVersion: IDL.Nat, schemaLog: IDL.Vec(IDL.Text),
  indexes: IDL.Vec(IndexInfo), dedupeSize: IDL.Nat, writeCalls: IDL.Nat, writeOps: IDL.Nat,
  writeInstructions: IDL.Nat, lastWriteInstructions: IDL.Nat64, storeInstructions: IDL.Nat,
});

export const shardIdl: IDL.InterfaceFactory = () =>
  IDL.Service({
    assign: IDL.Func([Assignment], [], []),
    setAccess: IDL.Func([Access], [], []),
    write: IDL.Func([IDL.Record({ route: Route, requestId: Bytes, ops: IDL.Vec(WriteOp) })], [Res(IDL.Vec(IDL.Nat64))], []),
    get: IDL.Func([GetReq], [Res(IDL.Vec(IDL.Opt(Entry)))], ["query"]),
    getCertainly: IDL.Func([GetReq], [Res(IDL.Vec(IDL.Opt(Entry)))], []),
    scan: IDL.Func([ScanReq], [Res(IDL.Record({ entries: IDL.Vec(Entry), next: IDL.Opt(Bytes) }))], ["query"]),
    ixScan: IDL.Func([IxScanReq], [Res(IDL.Record({ rows: IDL.Vec(IxRow), more: IDL.Bool }))], ["query"]),
    routeCheck: IDL.Func([Route, Bytes], [Res(IDL.Nat32)], ["query"]),
    status: IDL.Func([], [IDL.Record({ index: IDL.Principal, assignment: Assignment, accessVersion: IDL.Nat64 })], ["query"]),
    stats: IDL.Func([], [Stats], ["query"]),
    version: IDL.Func([], [IDL.Text], ["query"]),
  });
export const shardInit = (index: unknown) => IDL.encode([IDL.Record({ index: IDL.Principal })], [{ index }]);

export const indexIdl: IDL.InterfaceFactory = () =>
  IDL.Service({
    registerShards: IDL.Func([IDL.Vec(IDL.Principal), IDL.Nat8], [], []),
    shardMap: IDL.Func([], [ShardMapT], ["query"]),
    addWriter: IDL.Func([IDL.Principal], [], []),
    removeWriter: IDL.Func([IDL.Principal], [], []),
    setReaders: IDL.Func([Readers], [], []),
    getAccess: IDL.Func([], [Access], ["query"]),
    version: IDL.Func([], [IDL.Text], ["query"]),
  });
