/// Ekvm shard canister (M1): single-shard data operations, local secondary
/// indexes, access control, dedupe. The schema is chosen at build time via the
/// moc package `ekvm-schema` (DESIGN.md §3, D4); see scripts/build.sh.
import Prim "mo:⛔";
import Array "mo:core/Array";
import Cycles "mo:core/Cycles";
import IC "mo:core/InternetComputer";
import Iter "mo:core/Iter";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat16 "mo:core/Nat16";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Runtime "mo:core/Runtime";
import Time "mo:core/Time";
import UserSchema "mo:ekvm-schema/Schema";
import Routing "../src/Routing";
import S "../src/Schema";
import Store "../src/Store";
import T "../src/Types";

actor class Shard(init : { index : Principal; ixLayout : ?Store.Layout }) {
  let index : Principal = init.index;
  var assignment : T.Assignment = { epoch = 0; slotBits = 16; acceptPrevSlotBits = null; owned = [] };
  var access : T.Access = { version = 0; writers = []; readers = #public_ };
  var writers : Map.Map<Principal, ()> = Map.empty();
  var readers : ?Map.Map<Principal, ()> = null; // null = public
  let store : Store.State = Store.newWithLayout(switch (init.ixLayout) { case (?l) l; case null Store.defaultLayout });

  // Metrics (DESIGN.md §12): instruction counts are this message's own counter at reply time.
  var writeCalls : Nat = 0;
  var writeOps : Nat = 0;
  var writeInstructions : Nat = 0;
  var lastWriteInstructions : Nat64 = 0;
  /// Instructions spent inside Store.write (index maintenance included), excluding
  /// argument decoding, auth, route check and dedupe.
  var storeInstructions : Nat = 0;

  transient let limits = Store.defaultLimits;
  /// Leave ~1 B headroom under the 5 B query instruction limit.
  transient let queryBudget : Nat64 = 4_000_000_000;

  // Runs on install and on every upgrade: reconcile indexes with the compiled-in schema.
  transient let schemaLog : [Text] = do {
    switch (S.validate(UserSchema.schema)) { case (?e) Runtime.trap("invalid schema: " # e); case null {} };
    Store.syncSchema(store, UserSchema.schema);
  };

  func requireIndex(caller : Principal) {
    if (caller != index) Runtime.trap("unauthorized: index only");
  };

  func canWrite(caller : Principal) : Bool = writers.containsKey(caller);

  func canRead(caller : Principal) : Bool {
    switch readers { case null true; case (?m) m.containsKey(caller) or m.containsKey(Principal.anonymous()) };
  };

  func overBudget() : Bool = IC.performanceCounter(0) > queryBudget;

  func checkKeys(route : T.Route, keys : [T.Key]) : ?T.Err {
    for (k in keys.values()) {
      switch (Routing.check(assignment, route, k.pk)) { case (#err e) return ?e; case (#ok _) {} };
    };
    null;
  };

  func opKey(op : T.WriteOp) : T.Key = switch op { case (#put p) p.key; case (#delete d) d.key };

  // ------------------------------------------------------------ index-only

  /// Index pushes this shard's slot ranges.
  public shared ({ caller }) func assign(a : T.Assignment) : async () {
    requireIndex(caller);
    if (a.slotBits < 1 or a.slotBits > 32) Runtime.trap("invalid slotBits");
    assignment := a;
  };

  /// Index pushes the versioned writer/reader allowlist. Stale versions are ignored.
  public shared ({ caller }) func setAccess(a : T.Access) : async () {
    requireIndex(caller);
    if (a.version <= access.version) return;
    access := a;
    writers := Map.fromIter<Principal, ()>(a.writers.values().map<Principal, (Principal, ())>(func p = (p, ())), Principal.compare);
    readers := switch (a.readers) {
      case (#public_) null;
      case (#allow ps) ?Map.fromIter<Principal, ()>(ps.values().map<Principal, (Principal, ())>(func p = (p, ())), Principal.compare);
    };
  };

  // ------------------------------------------------------------ data

  /// Atomic batch write on this shard, including local index maintenance.
  public shared ({ caller }) func write(req : T.WriteReq) : async T.WriteResult {
    if (not canWrite(caller)) return #err(#unauthorized);
    if (req.requestId.size() > limits.maxRequestId) return #err(#tooLarge);
    switch (checkKeys(req.route, req.ops.map<T.WriteOp, T.Key>(opKey))) { case (?e) return #err(e); case null {} };
    let now = Time.now();
    Store.dedupePurge(store, now, limits, 64);
    switch (Store.dedupeLookup(store, req.requestId, now, limits)) { case (?r) return r; case null {} };
    let s0 = IC.performanceCounter(0);
    let r = Store.write(store, UserSchema.schema, req.ops, limits);
    storeInstructions += (IC.performanceCounter(0) - s0).toNat();
    switch r {
      case (#ok _ or #err(#conflict _)) Store.dedupeRecord(store, req.requestId, now, r);
      case _ {};
    };
    writeCalls += 1;
    writeOps += req.ops.size();
    let ins = IC.performanceCounter(0);
    lastWriteInstructions := ins;
    writeInstructions += ins.toNat();
    r;
  };

  func doGet(caller : Principal, req : T.GetReq) : Result.Result<[?T.Entry], T.Err> {
    if (not canRead(caller)) return #err(#unauthorized);
    switch (checkKeys(req.route, req.keys)) { case (?e) return #err(e); case null {} };
    Store.get(store, req.keys, limits);
  };

  public shared query ({ caller }) func get(req : T.GetReq) : async Result.Result<[?T.Entry], T.Err> {
    doGet(caller, req);
  };

  /// Read-your-writes: the same read through consensus (DESIGN.md §10).
  public shared ({ caller }) func getCertainly(req : T.GetReq) : async Result.Result<[?T.Entry], T.Err> {
    doGet(caller, req);
  };

  public shared query ({ caller }) func scan(req : T.ScanReq) : async Result.Result<T.ScanPage, T.Err> {
    if (not canRead(caller)) return #err(#unauthorized);
    switch (Routing.check(assignment, req.route, req.pk)) { case (#err e) return #err e; case (#ok _) {} };
    #ok(Store.scan(store, req.pk, req.from, req.to, req.limit, req.reverse, limits, overBudget));
  };

  public shared query ({ caller }) func ixScan(req : T.IxScanReq) : async Result.Result<T.IxPage, T.Err> {
    if (not canRead(caller)) return #err(#unauthorized);
    switch (Routing.checkSlice(assignment, req.route)) { case (#err e) return #err e; case (#ok) {} };
    Store.ixScan(store, req, limits, overBudget);
  };

  // ------------------------------------------------------------ introspection

  public type ExplainReq = { #get : T.GetReq; #scan : T.ScanReq; #ixScan : T.IxScanReq };
  /// Cost of one read, measured inside this query (benchmarks, DESIGN.md §12).
  public type Explain = { instructions : Nat64; rows : Nat; bytes : Nat; ok : Bool };

  /// Runs the read like the real query and reports its instruction count
  /// (the counter at the end of the work, before reply encoding).
  public shared query ({ caller }) func explain(req : ExplainReq) : async Explain {
    func entryBytes(e : T.Entry) : Nat = e.key.pk.size() + e.key.sk.size() + e.value.size();
    let (ok, rows, bytes) : (Bool, Nat, Nat) = switch req {
      case (#get g) {
        switch (doGet(caller, g)) {
          case (#ok es) { var b = 0; var n = 0; for (e in es.values()) switch e { case (?x) { b += entryBytes(x); n += 1 }; case null {} }; (true, n, b) };
          case (#err _) (false, 0, 0);
        };
      };
      case (#scan r) {
        if (not canRead(caller)) (false, 0, 0) else switch (Routing.check(assignment, r.route, r.pk)) {
          case (#err _) (false, 0, 0);
          case (#ok _) {
            let p = Store.scan(store, r.pk, r.from, r.to, r.limit, r.reverse, limits, overBudget);
            var b = 0;
            for (e in p.entries.values()) b += entryBytes(e);
            (true, p.entries.size(), b);
          };
        };
      };
      case (#ixScan r) {
        if (not canRead(caller)) (false, 0, 0) else switch (Routing.checkSlice(assignment, r.route)) {
          case (#err _) (false, 0, 0);
          case (#ok) {
            switch (Store.ixScan(store, r, limits, overBudget)) {
              case (#ok p) {
                var b = 0;
                for (x in p.rows.values()) b += x.ixKey.size() + x.key.pk.size() + x.key.sk.size() + (switch (x.value) { case (?v) v.size(); case null 0 });
                (true, p.rows.size(), b);
              };
              case (#err _) (false, 0, 0);
            };
          };
        };
      };
    };
    { instructions = IC.performanceCounter(0); rows; bytes; ok };
  };

  public query func routeCheck(route : T.Route, pk : Blob) : async Result.Result<Nat32, T.Err> {
    Routing.check(assignment, route, pk);
  };

  public query func version() : async Text { "ekvm-shard/0.3.0 (M3)" };

  public query func status() : async { index : Principal; assignment : T.Assignment; accessVersion : Nat64 } {
    { index; assignment; accessVersion = access.version };
  };

  public type IndexInfo = { id : Nat16; name : Text; ready : Bool; entries : Nat };
  public type Stats = {
    entries : Nat;
    bytes : Nat;
    lastVersion : Nat64;
    schemaVersion : Nat;
    schemaLog : [Text];
    indexes : [IndexInfo];
    dedupeSize : Nat;
    writeCalls : Nat;
    writeOps : Nat;
    writeInstructions : Nat;
    lastWriteInstructions : Nat64;
    storeInstructions : Nat;
    ixLayout : Store.Layout;
    /// Wasm heap in use / total memory / cycles balance (DESIGN.md §8, §12).
    heapBytes : Nat;
    /// Largest live heap seen at the end of a GC cycle (lags the current size).
    maxLiveBytes : Nat;
    memoryBytes : Nat;
    cycles : Nat;
  };

  public query func stats() : async Stats {
    {
      entries = store.primary.size();
      bytes = store.bytes;
      lastVersion = store.lastVersion;
      schemaVersion = store.schemaVersion;
      schemaLog;
      indexes = Store.indexStatus(store).map<(Nat16, Text, Store.IndexStatus, Nat), IndexInfo>(
        func((id, name, st, n)) = { id; name; ready = st == #ready; entries = n }
      );
      dedupeSize = store.dedupe.size();
      writeCalls;
      writeOps;
      writeInstructions;
      lastWriteInstructions;
      storeInstructions;
      ixLayout = store.layout;
      heapBytes = Prim.rts_heap_size();
      maxLiveBytes = Prim.rts_max_live_size();
      memoryBytes = Prim.rts_memory_size();
      cycles = Cycles.balance();
    };
  };

  /// Early ingress filter (single replica, DESIGN.md §7); methods re-check.
  system func inspect({ caller : Principal; msg : {
    #assign : Any;
    #setAccess : Any;
    #write : Any;
    #getCertainly : Any;
    #get : Any;
    #scan : Any;
    #ixScan : Any;
    #routeCheck : Any;
    #version : Any;
    #status : Any;
    #stats : Any;
    #explain : Any;
  } }) : Bool {
    switch msg {
      // The index is a canister, so these normally never arrive as ingress; a
      // principal configured as `index` (tests, operators) may still call them.
      case (#assign _ or #setAccess _) caller == index;
      case (#write _) canWrite(caller);
      case (#getCertainly _) canRead(caller);
      case _ true;
    };
  };
};
