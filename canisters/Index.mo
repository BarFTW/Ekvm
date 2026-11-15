/// Ekvm index canister. Holds the shard map, its change log and the access
/// allowlist; serves the map (full or delta) to clients and pushes slot
/// assignments and allowlists to shards. Never on the data path (DESIGN.md §4.2).
/// Shard creation, top-up, moves and upgrade orchestration arrive in later milestones.
import Array "mo:core/Array";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import MapLog "../src/MapLog";
import ShardMap "../src/ShardMap";
import T "../src/Types";

actor class Index() {
  var map : T.ShardMap = { epoch = 0; slotBits = 16; shards = []; ranges = []; schemaVersion = 0 };
  let log : MapLog.Log = MapLog.new();
  /// Doubling rollout state: the map being rolled out (not yet published),
  /// and whether shards still accept the previous slotBits.
  var pendingDouble : ?T.ShardMap = null;
  var acceptPrev : ?Nat8 = null;

  var access : T.Access = { version = 0; writers = []; readers = #public_ };

  type ShardActor = actor {
    assign : (T.Assignment) -> async ();
    setAccess : (T.Access) -> async ();
  };

  func requireController(caller : Principal) {
    if (not caller.isController()) Runtime.trap("unauthorized: controllers only");
  };

  func shardActor(p : Principal) : ShardActor = actor (p.toText());

  /// Push each shard its assignment for `m`, all calls in flight at once.
  func pushAssignments(m : T.ShardMap, prev : ?Nat8) : async () {
    let calls = List.empty<async ()>();
    for (i in Nat.range(0, m.shards.size())) calls.add(shardActor(m.shards[i]).assign(ShardMap.assignment(m, i.toNat16(), prev)));
    for (c in calls.values()) await c;
  };

  func pushAccess(a : T.Access) : async () {
    let calls = List.empty<async ()>();
    for (p in map.shards.values()) calls.add(shardActor(p).setAccess(a));
    for (c in calls.values()) await c;
  };

  /// Clients fetch and cache this (DESIGN.md §4.2).
  public query func shardMap() : async T.ShardMap { map };

  /// Changes since a cached epoch, or the full map if that epoch is outside
  /// the change log window (last 256 changes) or predates a reset.
  public query func shardMapSince(epoch : Nat64) : async T.MapSince { MapLog.since(log, map, epoch) };

  /// Admin, once: register already-deployed shards with an even split of the
  /// slot space, then push assignments and the allowlist. Re-registration is
  /// refused because it would move data without a migration (M4).
  public shared ({ caller }) func registerShards(shards : [Principal], slotBits : Nat8) : async () {
    requireController(caller);
    if (map.shards.size() > 0) Runtime.trap("shards already registered; moves are M4");
    if (shards.size() == 0 or shards.size() > 65_536) Runtime.trap("need 1..65536 shards");
    if (slotBits < 1 or slotBits > 32) Runtime.trap("invalid slotBits");
    if (ShardMap.slotCount(slotBits) < shards.size()) Runtime.trap("fewer slots than shards");
    let next = ShardMap.even(shards, slotBits, map.epoch + 1);
    switch (ShardMap.validate(next)) { case (#err e) Runtime.trap(e); case (#ok) {} };
    // Commit before awaiting (DESIGN.md §10): shards are pushed after the map is persisted.
    map := next;
    MapLog.reset(log, next.epoch);
    await pushAssignments(next, null);
    await pushAccess(access);
  };

  /// Admin: slot doubling, zero data movement (DESIGN.md §4.1). Step 1 pushes
  /// the doubled assignment (shards accept old and new slotBits), step 2
  /// publishes the map at epoch + 1. Idempotent: a retry after a failed push
  /// resumes the same rollout. `finishDoubling` is step 3.
  public shared ({ caller }) func doubleSlots() : async T.ShardMap {
    requireController(caller);
    if (map.shards.size() == 0) Runtime.trap("no shards");
    if (acceptPrev != null and pendingDouble == null) Runtime.trap("previous doubling not finished");
    let next = switch pendingDouble {
      case (?p) p;
      case null {
        if (map.slotBits >= 32) Runtime.trap("slotBits already 32");
        let d = ShardMap.double(map);
        pendingDouble := ?d;
        acceptPrev := ?map.slotBits;
        d;
      };
    };
    await pushAssignments(next, acceptPrev);
    if (pendingDouble != null) {
      map := next;
      MapLog.record(log, next.epoch, #double, MapLog.defaultCap);
      pendingDouble := null;
    };
    map;
  };

  /// Admin: end a doubling rollout; shards then reject the old slotBits.
  public shared ({ caller }) func finishDoubling() : async () {
    requireController(caller);
    if (pendingDouble != null) Runtime.trap("doubling not yet published; call doubleSlots again");
    if (acceptPrev == null) Runtime.trap("no doubling in progress");
    acceptPrev := null;
    await pushAssignments(map, null);
  };

  /// Bump the allowlist version, commit, then push to every shard (DESIGN.md §7).
  /// Shards ignore stale versions, so concurrent pushes converge.
  func publish(next : { writers : [Principal]; readers : T.Readers }) : async () {
    access := { version = access.version + 1; writers = next.writers; readers = next.readers };
    await pushAccess(access);
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

  public query func status() : async { epoch : Nat64; slotBits : Nat8; shards : Nat; ranges : Nat; doubling : Bool; logSize : Nat } {
    { epoch = map.epoch; slotBits = map.slotBits; shards = map.shards.size(); ranges = map.ranges.size(); doubling = acceptPrev != null; logSize = MapLog.size(log) };
  };

  public query func version() : async Text { "ekvm-index/0.2.0 (M2)" };
};
