/// Ekvm index canister. Holds the shard map, its change log and the access
/// allowlist; serves the map (full or delta) to clients and pushes slot
/// assignments and allowlists to shards. Never on the data path (DESIGN.md §4.2).
/// M3: creates shards (actor-class instantiation, same subnet) and keeps them
/// funded (timer-driven top-up from `canister_status`, DESIGN.md §8). The
/// index wasm embeds the shard wasm, so both are built with the same schema
/// package (scripts/build.sh). Moves and upgrade orchestration: M4/M5.
import Array "mo:core/Array";
import Cycles "mo:core/Cycles";
import Error "mo:core/Error";
import Int "mo:core/Int";
import Time "mo:core/Time";
import Timer "mo:core/Timer";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import MapLog "../src/MapLog";
import ShardMap "../src/ShardMap";
import Store "../src/Store";
import T "../src/Types";
import ShardClass "Shard";

actor class Index() = self {
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

  // ------------------------------------------------------------ cycles (DESIGN.md §8)

  public type CyclesPolicy = {
    /// Timer period for the balance check.
    intervalNs : Nat;
    /// Top up a shard when its balance is below max(burnDays × daily idle burn, minBalance) ...
    minBalance : Nat;
    burnDays : Nat;
    /// ... by enough to reach `topUpFactor` × that threshold.
    topUpFactor : Nat;
    /// Never let a top-up take the index below this balance.
    indexReserve : Nat;
    /// `status().lowCycles` when the projected runway is shorter than this.
    lowRunwayDays : Nat;
  };

  public type ShardCycles = {
    shard : Principal;
    cycles : Nat;
    memorySize : Nat;
    idleBurnPerDay : Nat;
    reservedCycles : Nat;
    checkedAt : Int;
    topUps : Nat;
    toppedUp : Nat;
    lastError : ?Text;
  };

  var policy : CyclesPolicy = {
    intervalNs = 600_000_000_000; // 10 min
    minBalance = 1_000_000_000_000; // 1 T
    burnDays = 7;
    topUpFactor = 2;
    indexReserve = 1_000_000_000_000;
    lowRunwayDays = 30;
  };
  var shardCycles : [ShardCycles] = [];
  var checks : Nat = 0;
  /// Shards created by `createShards` but not yet registered (retry-safe).
  var created : [Principal] = [];

  type Mgmt = actor {
    canister_status : ({ canister_id : Principal }) -> async {
      cycles : Nat;
      memory_size : Nat;
      idle_cycles_burned_per_day : Nat;
      reserved_cycles : Nat;
    };
    deposit_cycles : ({ canister_id : Principal }) -> async ();
  };
  transient let mgmt : Mgmt = actor "aaaaa-aa";

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
    await register(shards, slotBits);
  };

  func register(shards : [Principal], slotBits : Nat8) : async () {
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

  /// Admin, once: create `n` shards on this subnet, each funded with
  /// `cyclesPerShard` (creation fee included), then register them like
  /// `registerShards`. A retry after a partial failure reuses the shards
  /// already created. Cross-subnet placement is M5 (DESIGN.md §8).
  public shared ({ caller }) func createShards(n : Nat, slotBits : Nat8, opts : { cyclesPerShard : Nat; ixLayout : ?Store.Layout }) : async [Principal] {
    requireController(caller);
    if (map.shards.size() > 0) Runtime.trap("shards already registered; moves are M4");
    if (n == 0 or n > 1024) Runtime.trap("need 1..1024 shards per call");
    if (n < created.size()) Runtime.trap("more shards already created than requested");
    let need = Nat.sub(n, created.size()) * opts.cyclesPerShard + policy.indexReserve;
    if (Cycles.balance() < need) Runtime.trap("index balance too low: need " # need.toText() # " cycles");
    let me = Principal.fromActor(self);
    // Waves of up to 10 concurrent creations; each finished shard is recorded
    // before the next await, so a retry resumes without leaking canisters.
    while (created.size() < n) {
      let wave = Nat.min(10, Nat.sub(n, created.size()));
      let fs = List.empty<async ShardClass.Shard>();
      for (_ in Nat.range(0, wave)) fs.add((with cycles = opts.cyclesPerShard) ShardClass.Shard({ index = me; ixLayout = opts.ixLayout }));
      var failed : ?Text = null;
      for (f in fs.values()) {
        try {
          let s = await f;
          created := created.concat([Principal.fromActor(s)]);
        } catch (e) { failed := ?e.message() };
      };
      // `throw` (unlike a trap) keeps the shards recorded so far for the retry.
      switch failed { case (?m) throw Error.reject("shard creation failed: " # m); case null {} };
    };
    let shards = created;
    await register(shards, slotBits);
    created := [];
    shards;
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

  func threshold(burn : Nat) : Nat = Nat.max(policy.burnDays * burn, policy.minBalance);

  /// One pass over all shards: read `canister_status`, top up the low ones.
  /// Status calls run in parallel; deposits are sequential so the reserve check holds.
  func checkCycles() : async () {
    let shards = map.shards;
    let calls = List.empty<async { cycles : Nat; memory_size : Nat; idle_cycles_burned_per_day : Nat; reserved_cycles : Nat }>();
    for (p in shards.values()) calls.add(mgmt.canister_status({ canister_id = p }));
    let prev = shardCycles;
    let out = List.empty<ShardCycles>();
    var i = 0;
    for (c in calls.values()) {
      let p = shards[i];
      i += 1;
      let old = prev.find(func(x : ShardCycles) : Bool = x.shard == p);
      var topUps = switch old { case (?o) o.topUps; case null 0 };
      var toppedUp = switch old { case (?o) o.toppedUp; case null 0 };
      try {
        let st = await c;
        var bal = st.cycles;
        var err : ?Text = null;
        let th = threshold(st.idle_cycles_burned_per_day);
        if (bal < th) {
          let amount = Nat.sub(policy.topUpFactor * th, bal);
          if (Cycles.balance() >= amount + policy.indexReserve) {
            try {
              await (with cycles = amount) mgmt.deposit_cycles({ canister_id = p });
              bal += amount;
              topUps += 1;
              toppedUp += amount;
            } catch (e) { err := ?("deposit failed: " # e.message()) };
          } else err := ?"index balance too low to top up";
        };
        out.add({ shard = p; cycles = bal; memorySize = st.memory_size; idleBurnPerDay = st.idle_cycles_burned_per_day; reservedCycles = st.reserved_cycles; checkedAt = Time.now(); topUps; toppedUp; lastError = err });
      } catch (e) {
        let base = switch old { case (?o) o; case null { { shard = p; cycles = 0; memorySize = 0; idleBurnPerDay = 0; reservedCycles = 0; checkedAt = 0; topUps; toppedUp; lastError = null } } };
        out.add({ base with checkedAt = Time.now(); lastError = ?("canister_status failed: " # e.message()) });
      };
    };
    shardCycles := out.toArray();
    checks += 1;
  };

  transient var timer : Nat = 0;
  func startTimer<system>() {
    Timer.cancelTimer(timer);
    timer := Timer.recurringTimer<system>(#nanoseconds(policy.intervalNs), checkCycles);
  };
  // Timers do not survive upgrades; the actor body re-arms on install and upgrade.
  startTimer<system>();

  public shared ({ caller }) func setCyclesPolicy(p : CyclesPolicy) : async () {
    requireController(caller);
    if (p.intervalNs < 1_000_000_000 or p.topUpFactor < 1) Runtime.trap("invalid policy");
    policy := p;
    startTimer<system>();
  };

  public query func cyclesPolicy() : async CyclesPolicy { policy };

  /// Admin: run the balance check now (the timer runs it every `intervalNs`).
  public shared ({ caller }) func checkCyclesNow() : async [ShardCycles] {
    requireController(caller);
    await checkCycles();
    shardCycles;
  };

  /// Last observed per-shard balances, memory and top-ups.
  public query func shardCycleStatus() : async { checks : Nat; shards : [ShardCycles] } {
    { checks; shards = shardCycles };
  };

  /// Days the index can keep every shard above its threshold at the observed
  /// idle burn (null: no burn observed yet).
  func runwayDays() : ?Nat {
    var burn = 0;
    for (s in shardCycles.values()) burn += s.idleBurnPerDay;
    if (burn == 0) null else ?((Nat.sub(Nat.max(Cycles.balance(), policy.indexReserve), policy.indexReserve)) / burn);
  };

  public type Status = {
    epoch : Nat64;
    slotBits : Nat8;
    shards : Nat;
    ranges : Nat;
    doubling : Bool;
    logSize : Nat;
    cycles : Nat;
    runwayDays : ?Nat;
    lowCycles : Bool;
  };

  public query func status() : async Status {
    let runway = runwayDays();
    let low = Cycles.balance() < policy.indexReserve or (switch runway { case (?d) d < policy.lowRunwayDays; case null false });
    { epoch = map.epoch; slotBits = map.slotBits; shards = map.shards.size(); ranges = map.ranges.size(); doubling = acceptPrev != null; logSize = MapLog.size(log); cycles = Cycles.balance(); runwayDays = runway; lowCycles = low };
  };

  public query func version() : async Text { "ekvm-index/0.3.0 (M3)" };
};
