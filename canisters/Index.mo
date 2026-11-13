/// Ekvm index canister: M0 skeleton. Holds the shard map, serves it to clients
/// and pushes slot assignments to shards. Shard creation, top-up, split and
/// upgrade orchestration arrive in later milestones.
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import ShardMap "../src/ShardMap";
import T "../src/Types";

actor class Index() {
  var map : T.ShardMap = { epoch = 0; slotBits = 16; shards = []; ranges = []; schemaVersion = 0 };

  type ShardActor = actor { assign : (T.Assignment) -> async () };

  func requireController(caller : Principal) {
    if (not caller.isController()) Runtime.trap("unauthorized: controllers only");
  };

  /// Clients fetch and cache this (DESIGN.md §4.2).
  public query func shardMap() : async T.ShardMap { map };

  /// Admin: register already-deployed shards with an even split of the slot
  /// space, then push each shard its assignment. Bumps the epoch.
  public shared ({ caller }) func registerShards(shards : [Principal], slotBits : Nat8) : async () {
    requireController(caller);
    if (shards.size() == 0 or shards.size() > 65_536) Runtime.trap("need 1..65536 shards");
    if (slotBits < 1 or slotBits > 32) Runtime.trap("invalid slotBits");
    if (ShardMap.slotCount(slotBits) < shards.size()) Runtime.trap("fewer slots than shards");
    let next = ShardMap.even(shards, slotBits, map.epoch + 1);
    switch (ShardMap.validate(next)) { case (#err e) Runtime.trap(e); case (#ok) {} };
    // Commit before awaiting (DESIGN.md §10): shards are pushed after the map is persisted.
    map := next;
    for (i in Nat.range(0, shards.size())) {
      let s : ShardActor = actor (shards[i].toText());
      await s.assign(ShardMap.assignment(next, i.toNat16(), null));
    };
  };

  public query func version() : async Text { "ekvm-index/0.0.1 (M0)" };
};
