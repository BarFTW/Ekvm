// Candid IDL factories for the M0 canisters (mirrors build/*.did).
import { IDL } from "@icp-sdk/core/candid";

const Route = IDL.Record({ epoch: IDL.Nat64, slotBits: IDL.Nat8 });
const Key = IDL.Record({ pk: IDL.Vec(IDL.Nat8), sk: IDL.Vec(IDL.Nat8) });
const Err = IDL.Variant({
  wrongShard: IDL.Record({ epoch: IDL.Nat64, slotBits: IDL.Nat8 }),
  conflict: IDL.Record({ key: Key, current: IDL.Opt(IDL.Nat64) }),
  unauthorized: IDL.Null, tooLarge: IDL.Null, migrating: IDL.Null, unknownIndex: IDL.Null,
});
const Assignment = IDL.Record({
  epoch: IDL.Nat64, slotBits: IDL.Nat8, acceptPrevSlotBits: IDL.Opt(IDL.Nat8), owned: IDL.Vec(IDL.Tuple(IDL.Nat, IDL.Nat)),
});
const ShardMapT = IDL.Record({
  epoch: IDL.Nat64, slotBits: IDL.Nat8, shards: IDL.Vec(IDL.Principal),
  ranges: IDL.Vec(IDL.Tuple(IDL.Nat32, IDL.Nat16)), schemaVersion: IDL.Nat,
});

export const shardIdl: IDL.InterfaceFactory = () =>
  IDL.Service({
    assign: IDL.Func([Assignment], [], []),
    routeCheck: IDL.Func([Route, IDL.Vec(IDL.Nat8)], [IDL.Variant({ ok: IDL.Nat32, err: Err })], ["query"]),
    status: IDL.Func([], [IDL.Record({ index: IDL.Principal, assignment: Assignment })], ["query"]),
    version: IDL.Func([], [IDL.Text], ["query"]),
  });
export const shardInit = (index: unknown) => IDL.encode([IDL.Record({ index: IDL.Principal })], [{ index }]);

export const indexIdl: IDL.InterfaceFactory = () =>
  IDL.Service({
    registerShards: IDL.Func([IDL.Vec(IDL.Principal), IDL.Nat8], [], []),
    shardMap: IDL.Func([], [ShardMapT], ["query"]),
    version: IDL.Func([], [IDL.Text], ["query"]),
  });
