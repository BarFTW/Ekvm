/// Ekvm index canister. Holds the shard map and the access allowlist, serves
/// the map to clients and pushes slot assignments and allowlists to shards. Shard creation, top-up, split and
/// upgrade orchestration arrive in later milestones.
import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import ShardMap "../src/ShardMap";
import T "../src/Types";

actor class Index() {
  var map : T.ShardMap = { epoch = 0; slotBits = 16; shards = []; ranges = []; schemaVersion = 0 };

  var access : T.Access = { version = 0; writers = []; readers = #public_ };

  type ShardActor = actor {
    assign : (T.Assignment) -> async ();
    setAccess : (T.Access) -> async ();
  };

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
      await s.setAccess(access);
    };
  };

  /// Bump the allowlist version, commit, then push to every shard (DESIGN.md §7).
  /// Shards ignore stale versions, so concurrent pushes converge.
  func publish(next : { writers : [Principal]; readers : T.Readers }) : async () {
    access := { version = access.version + 1; writers = next.writers; readers = next.readers };
    let a = access;
    for (p in map.shards.values()) {
      let s : ShardActor = actor (p.toText());
      await s.setAccess(a);
    };
  };

  public shared ({ caller }) func addWriter(p : Principal) : async () {
    requireController(caller);
    if (access.writers.any(func(w : Principal) : Bool = w == p)) return;
    await publish({ writers = access.writers.concat([p]); readers = access.readers });
  };

  public shared ({ caller }) func removeWriter(p : Principal) : async () {
    requireController(caller);
    await publish({ writers = access.writers.filter(func(w : Principal) : Bool = w != p); readers = access.readers });
  };

  public shared ({ caller }) func setReaders(r : T.Readers) : async () {
    requireController(caller);
    await publish({ writers = access.writers; readers = r });
  };

  public query func getAccess() : async T.Access { access };

  public query func version() : async Text { "ekvm-index/0.1.0 (M1)" };
};
