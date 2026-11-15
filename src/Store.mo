/// Single-shard store (DESIGN.md §3, §5.2, §6, §10): primary data on
/// `mo:core/Map`, local secondary indexes maintained in the same message,
/// CAS, request dedupe, and bounded range scans. Pure module: the shard actor
/// owns a `State` and passes the schema, clock and instruction budget in.
///
/// Layout (structured keys, no byte concatenation on the write path):
/// - primary map  : Key -> Stored, ordered by (pk, sk)
/// - index maps   : IxPos { ixKey; key } -> (), ordered by (ixKey, pk, sk)
/// Component-wise order equals the byte order of `ixKey ‖ bytes(pk) ‖ sk`
/// (ENCODING.md) whenever ixKey is prefix-free, which all `Encode` outputs are.
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat16 "mo:core/Nat16";
import Nat64 "mo:core/Nat64";
import Order "mo:core/Order";
import Queue "mo:core/Queue";
import Encode "Encode";
import Schema "Schema";
import T "Types";

module {
  public type Stored = {
    key : T.Key;
    value : Blob;
    version : Nat64;
    /// Current (index id, encoded index key) pairs, used to remove stale index entries.
    ix : [(Nat16, Blob)];
  };

  /// `#building`: declared in the schema after data existed; maintained on
  /// write but not served until a backfill (M4) marks it `#ready`.
  public type IndexStatus = { #ready; #building };

  public type Index = {
    id : Nat16;
    var name : Text;
    var status : IndexStatus;
    map : Map.Map<T.IxPos, ()>;
  };

  public type DedupeRec = { at : Int; result : T.WriteResult };

  public type State = {
    primary : Map.Map<T.Key, Stored>;
    indexes : Map.Map<Nat16, Index>;
    dedupe : Map.Map<Blob, DedupeRec>;
    dedupeOrder : Queue.Queue<(Int, Blob)>;
    var lastVersion : Nat64;
    /// Approximate payload bytes: keys + values + index keys.
    var bytes : Nat;
    var schemaVersion : Nat;
  };

  public type Limits = {
    maxPk : Nat;
    maxSk : Nat;
    maxValue : Nat;
    maxOps : Nat;
    maxRows : Nat;
    maxGetKeys : Nat;
    /// Response payload cap for scans/gets (keys + values), in bytes.
    maxPageBytes : Nat;
    maxRequestId : Nat;
    dedupeTtlNs : Nat;
    maxDedupe : Nat;
  };

  public let defaultLimits : Limits = {
    maxPk = 1024;
    maxSk = 1024;
    maxValue = 1_048_576;
    maxOps = 1000;
    maxRows = 1000;
    maxGetKeys = 1000;
    maxPageBytes = 1_048_576;
    maxRequestId = 64;
    dedupeTtlNs = 600_000_000_000;
    maxDedupe = 100_000;
  };

  public func new() : State {
    {
      primary = Map.empty<T.Key, Stored>();
      indexes = Map.empty<Nat16, Index>();
      dedupe = Map.empty<Blob, DedupeRec>();
      dedupeOrder = Queue.empty<(Int, Blob)>();
      var lastVersion = 0;
      var bytes = 0;
      var schemaVersion = 0;
    };
  };

  // ---------------------------------------------------------------- keys and order

  public func compareKey(a : T.Key, b : T.Key) : Order.Order {
    switch (Blob.compare(a.pk, b.pk)) { case (#equal) Blob.compare(a.sk, b.sk); case o o };
  };

  public func compareIxPos(a : T.IxPos, b : T.IxPos) : Order.Order {
    switch (Blob.compare(a.ixKey, b.ixKey)) { case (#equal) compareKey(a.key, b.key); case o o };
  };

  /// Byte form of an index position, `ixKey ‖ bytes(pk) ‖ sk` (ENCODING.md);
  /// for clients that merge rows as opaque bytes. Not used on the write path.
  public func physicalIxKey(p : T.IxPos) : Blob = Encode.tuple([p.ixKey, Encode.bytes(p.key.pk), p.key.sk]);

  /// Smallest blob greater than every blob with prefix `b`; null if none (b is all 0xFF or empty).
  public func prefixSucc(b : Blob) : ?Blob {
    let a = b.toArray();
    var n = a.size();
    while (n > 0 and a[n - 1] == 0xff) n -= 1;
    if (n == 0) return null;
    ?Array.tabulate<Nat8>(n, func i = if (i + 1 == n) a[i] + 1 else a[i]).toBlob();
  };

  /// Smallest blob strictly greater than `b`: b ‖ 00.
  public func succ(b : Blob) : Blob = Encode.tuple([b, "\00"]);

  func storedBytes(s : Stored) : Nat {
    var n = s.key.pk.size() + s.key.sk.size() + s.value.size();
    for ((_, k) in s.ix.values()) n += k.size();
    n;
  };

  // ---------------------------------------------------------------- schema

  /// Reconcile the index set with the compiled-in schema (on init and upgrade).
  /// New indexes start `#ready` on an empty shard and `#building` otherwise;
  /// indexes no longer declared are dropped. Returns a human-readable log.
  public func syncSchema<V>(st : State, schema : Schema.Schema<V>) : [Text] {
    let log = List.empty<Text>();
    let empty = st.primary.size() == 0;
    for (d in schema.indexes.values()) {
      switch (st.indexes.get(d.id)) {
        case (?ix) { ix.name := d.name };
        case null {
          st.indexes.add(d.id, { id = d.id; var name = d.name; var status = if empty #ready else #building; map = Map.empty<T.IxPos, ()>() });
          log.add("added index " # d.id.toText() # " " # d.name # (if empty "" else " (building)"));
        };
      };
    };
    for (id in st.indexes.keys().toArray().values()) {
      if (not schema.indexes.any(func(d : Schema.IndexDef<V>) : Bool = d.id == id)) {
        switch (st.indexes.take(id)) {
          case (?ix) log.add("dropped index " # id.toText() # " " # ix.name);
          case null {};
        };
      };
    };
    // Stored.ix may still name dropped indexes; `apply` ignores ids without a map.
    st.schemaVersion := schema.version;
    log.toArray();
  };

  public func indexStatus(st : State) : [(Nat16, Text, IndexStatus, Nat)] {
    st.indexes.values().map<Index, (Nat16, Text, IndexStatus, Nat)>(func ix = (ix.id, ix.name, ix.status, ix.map.size())).toArray();
  };

  public func setIndexReady(st : State, id : Nat16) : Bool {
    switch (st.indexes.get(id)) { case (?ix) { ix.status := #ready; true }; case null false };
  };

  func extractAll<V>(schema : Schema.Schema<V>, key : T.Key, value : Blob) : [(Nat16, Blob)] {
    if (schema.indexes.size() == 0) return [];
    let v = switch (schema.decode(value)) { case (?v) v; case null return [] };
    let out = List.empty<(Nat16, Blob)>();
    for (d in schema.indexes.values()) {
      switch (d.extract(key.pk, key.sk, v)) { case (?k) out.add((d.id, k)); case null {} };
    };
    out.toArray();
  };

  func ixOf(ix : [(Nat16, Blob)], id : Nat16) : ?Blob {
    for ((i, k) in ix.values()) if (i == id) return ?k;
    null;
  };

  // ---------------------------------------------------------------- reads

  func toEntry(s : Stored) : T.Entry = { key = s.key; value = s.value; version = s.version };

  public func getEntry(st : State, k : T.Key) : ?T.Entry {
    switch (st.primary.get(compareKey, k)) { case (?s) ?toEntry(s); case null null };
  };

  public func get(st : State, keys : [T.Key], limits : Limits) : {
    #ok : [?T.Entry];
    #err : T.Err;
  } {
    if (keys.size() > limits.maxGetKeys) return #err(#tooLarge);
    var bytes = 0;
    let out = List.empty<?T.Entry>();
    for (k in keys.values()) {
      let e = getEntry(st, k);
      switch (e) { case (?x) bytes += x.key.pk.size() + x.key.sk.size() + x.value.size(); case null {} };
      if (bytes > 2 * limits.maxPageBytes) return #err(#tooLarge);
      out.add(e);
    };
    #ok(out.toArray());
  };

  /// Iterator over map entries with key in [lo, hi) (hi = null: unbounded),
  /// ascending or descending; `lo = null` means unbounded below.
  func range<K, V>(m : Map.Map<K, V>, cmp : (K, K) -> Order.Order, lo : ?K, hi : ?K, reverse : Bool) : {
    next : () -> ?(K, V);
  } {
    if (not reverse) {
      let it = switch lo { case (?l) m.entriesFrom(cmp, l); case null m.entries() };
      var done = false;
      {
        next = func() : ?(K, V) {
          if (done) return null;
          switch (it.next()) {
            case (?(k, v)) {
              switch hi { case (?h) { if (cmp(k, h) != #less) { done := true; return null } }; case null {} };
              ?(k, v);
            };
            case null { done := true; null };
          };
        };
      };
    } else {
      let it = switch hi { case (?h) m.reverseEntriesFrom(cmp, h); case null m.reverseEntries() };
      var done = false;
      {
        next = func() : ?(K, V) {
          if (done) return null;
          var r : ?(K, V) = null;
          label l loop {
            switch (it.next()) {
              case (?(k, v)) {
                let isHi = switch hi { case (?h) cmp(k, h) == #equal; case null false };
                if (not isHi) {
                  switch lo { case (?l) { if (cmp(k, l) == #less) { done := true; break l } }; case null {} };
                  r := ?(k, v);
                  break l;
                };
              };
              case null { done := true; break l };
            };
          };
          r;
        };
      };
    };
  };

  /// Scan one partition by sort key. Bounds compare `sk` exactly.
  /// Stops at `limit` (0 = max), the page byte cap, or when `overBudget()`.
  public func scan(
    st : State,
    pk : Blob,
    from : T.Bound,
    to : T.Bound,
    limit : Nat,
    reverse : Bool,
    limits : Limits,
    overBudget : () -> Bool,
  ) : T.ScanPage {
    func kk(p : Blob, s : Blob) : T.Key = { pk = p; sk = s };
    let lo : T.Key = switch from { case (#unbounded) kk(pk, ""); case (#incl s) kk(pk, s); case (#excl s) kk(pk, succ(s)) };
    // (pk ‖ 00, "") is the smallest key after every key of partition pk.
    let hi : T.Key = switch to { case (#unbounded) kk(succ(pk), ""); case (#incl s) kk(pk, succ(s)); case (#excl s) kk(pk, s) };
    let max = if (limit == 0 or limit > limits.maxRows) limits.maxRows else limit;
    let it = range(st.primary, compareKey, ?lo, ?hi, reverse);
    let out = List.empty<T.Entry>();
    var bytes = 0;
    var last : ?Blob = null;
    loop {
      switch (it.next()) {
        case null return { entries = out.toArray(); next = null };
        case (?(_, s)) {
          let b = s.key.pk.size() + s.key.sk.size() + s.value.size() + 16;
          if (out.size() >= max or (out.size() > 0 and (bytes + b > limits.maxPageBytes or overBudget()))) {
            return { entries = out.toArray(); next = last };
          };
          out.add(toEntry(s));
          bytes += b;
          last := ?s.key.sk;
        };
      };
    };
  };

  let minKey : T.Key = { pk = ""; sk = "" };

  /// Scan this shard's slice of a local index in (ixKey, pk, sk) order.
  /// Bounds are prefix bounds on the encoded index key: `#incl b` as lower
  /// bound starts at b, as upper bound includes every key with prefix b;
  /// `#excl b` excludes every key with prefix b. `after` resumes strictly
  /// after a position.
  public func ixScan(
    st : State,
    req : {
      index : Nat16;
      from : T.Bound;
      to : T.Bound;
      after : ?T.IxPos;
      limit : Nat;
      reverse : Bool;
      withValues : Bool;
    },
    limits : Limits,
    overBudget : () -> Bool,
  ) : { #ok : T.IxPage; #err : T.Err } {
    let ix = switch (st.indexes.get(req.index)) {
      case (?ix) { if (ix.status != #ready) return #err(#unknownIndex); ix };
      case null return #err(#unknownIndex);
    };
    let none = #ok({ rows = []; more = false });
    func at(b : Blob) : T.IxPos = { ixKey = b; key = minKey };
    var lo : ?T.IxPos = switch (req.from) {
      case (#unbounded) null;
      case (#incl b) ?at(b);
      case (#excl b) { switch (prefixSucc(b)) { case (?s) ?at(s); case null return none } };
    };
    var hi : ?T.IxPos = switch (req.to) {
      case (#unbounded) null;
      case (#incl b) { switch (prefixSucc(b)) { case (?s) ?at(s); case null null } };
      case (#excl b) ?at(b);
    };
    var skipEq : ?T.IxPos = null;
    switch (req.after) {
      case (?a) {
        if (not req.reverse) {
          let later = switch lo { case (?l) compareIxPos(a, l) != #less; case null true };
          if (later) { lo := ?a; skipEq := ?a };
        } else {
          let earlier = switch hi { case (?h) compareIxPos(a, h) == #less; case null true };
          if (earlier) hi := ?a;
        };
      };
      case null {};
    };
    let max = if (req.limit == 0 or req.limit > limits.maxRows) limits.maxRows else req.limit;
    let it = range(ix.map, compareIxPos, lo, hi, req.reverse);
    let out = List.empty<T.IxRow>();
    var bytes = 0;
    loop {
      switch (it.next()) {
        case null return #ok({ rows = out.toArray(); more = false });
        case (?(pos, _)) {
          let skip = switch skipEq { case (?e) compareIxPos(pos, e) == #equal; case null false };
          if (not skip) {
            switch (st.primary.get(compareKey, pos.key)) {
              case null {}; // unreachable: index and primary change in the same message
              case (?s) {
                let value : ?Blob = if (req.withValues) ?s.value else null;
                let b = pos.ixKey.size() + pos.key.pk.size() + pos.key.sk.size() + 24 + (if (req.withValues) s.value.size() else 0);
                if (out.size() >= max or (out.size() > 0 and (bytes + b > limits.maxPageBytes or overBudget()))) {
                  return #ok({ rows = out.toArray(); more = true });
                };
                out.add({ ixKey = pos.ixKey; key = pos.key; version = s.version; value });
                bytes += b;
              };
            };
          };
        };
      };
    };
  };

  // ---------------------------------------------------------------- writes

  func condOk(c : T.Cond, cur : ?Stored) : Bool {
    switch (c, cur) {
      case (#any, _) true;
      case (#absent, null) true;
      case (#absent, ?_) false;
      case (#version v, ?s) s.version == v;
      case (#version _, null) false;
    };
  };

  func keyOk(k : T.Key, limits : Limits) : Bool = k.pk.size() <= limits.maxPk and k.sk.size() <= limits.maxSk;

  /// Validate sizes without touching state.
  public func validateOps(ops : [T.WriteOp], limits : Limits) : ?T.Err {
    if (ops.size() > limits.maxOps) return ?#tooLarge;
    for (op in ops.values()) {
      switch op {
        case (#put p) { if (not keyOk(p.key, limits) or p.value.size() > limits.maxValue) return ?#tooLarge };
        case (#delete d) { if (not keyOk(d.key, limits)) return ?#tooLarge };
      };
    };
    null;
  };

  /// All-or-nothing batch write (ops apply in order; later ops see earlier
  /// ones). Returns one fresh version per op. Index entries are updated in
  /// the same message; unchanged index keys are left alone.
  public func write<V>(st : State, schema : Schema.Schema<V>, ops : [T.WriteOp], limits : Limits) : T.WriteResult {
    switch (validateOps(ops, limits)) { case (?e) return #err(e); case null {} };
    if (ops.size() == 1) return writeOne(st, schema, ops[0]);
    let pending = Map.empty<T.Key, ?Stored>();
    let touched = List.empty<T.Key>();
    let versions = List.empty<Nat64>();
    var v = st.lastVersion;
    for (op in ops.values()) {
      let (key, cond) : (T.Key, T.Cond) = switch op { case (#put p) (p.key, p.cond); case (#delete d) (d.key, d.cond) };
      let cur : ?Stored = switch (pending.get(compareKey, key)) {
        case (?p) p;
        case null { touched.add(key); st.primary.get(compareKey, key) };
      };
      if (not condOk(cond, cur)) {
        return #err(#conflict { key; current = switch cur { case (?s) ?s.version; case null null } });
      };
      v += 1;
      switch op {
        case (#put p) pending.add(compareKey, key, ?{ key; value = p.value; version = v; ix = extractAll(schema, key, p.value) });
        case (#delete _) pending.add(compareKey, key, null);
      };
      versions.add(v);
    };
    for (key in touched.values()) {
      switch (pending.get(compareKey, key)) {
        case (?next) apply(st, key, st.primary.get(compareKey, key), next);
        case null {};
      };
    };
    st.lastVersion := v;
    #ok(versions.toArray());
  };

  /// Single-op fast path: no pending overlay.
  func writeOne<V>(st : State, schema : Schema.Schema<V>, op : T.WriteOp) : T.WriteResult {
    let (key, cond) : (T.Key, T.Cond) = switch op { case (#put p) (p.key, p.cond); case (#delete d) (d.key, d.cond) };
    let cur = st.primary.get(compareKey, key);
    if (not condOk(cond, cur)) {
      return #err(#conflict { key; current = switch cur { case (?s) ?s.version; case null null } });
    };
    let v = st.lastVersion + 1;
    let next : ?Stored = switch op {
      case (#put p) ?{ key; value = p.value; version = v; ix = extractAll(schema, key, p.value) };
      case (#delete _) null;
    };
    apply(st, key, cur, next);
    st.lastVersion := v;
    #ok([v]);
  };

  func apply(st : State, key : T.Key, old : ?Stored, next : ?Stored) {
    let oldIx = switch old { case (?o) o.ix; case null [] };
    let newIx = switch next { case (?n) n.ix; case null [] };
    for ((id, k) in oldIx.values()) {
      if (ixOf(newIx, id) != ?k) {
        switch (st.indexes.get(id)) { case (?ix) ix.map.remove(compareIxPos, { ixKey = k; key }); case null {} };
      };
    };
    for ((id, k) in newIx.values()) {
      if (ixOf(oldIx, id) != ?k) {
        switch (st.indexes.get(id)) { case (?ix) ix.map.add(compareIxPos, { ixKey = k; key }, ()); case null {} };
      };
    };
    switch old { case (?o) st.bytes -= Nat.min(st.bytes, storedBytes(o)); case null {} };
    switch next {
      case (?n) { st.primary.add(compareKey, key, n); st.bytes += storedBytes(n) };
      case null { if (old != null) st.primary.remove(compareKey, key) };
    };
  };

  // ---------------------------------------------------------------- dedupe

  public func dedupeLookup(st : State, requestId : Blob, now : Int, limits : Limits) : ?T.WriteResult {
    if (requestId.size() == 0) return null;
    switch (st.dedupe.get(requestId)) {
      case (?r) { if (now - r.at <= limits.dedupeTtlNs) ?r.result else null };
      case null null;
    };
  };

  /// Forget expired ids (bounded work per call) and enforce the size cap.
  public func dedupePurge(st : State, now : Int, limits : Limits, maxSteps : Nat) {
    var steps = 0;
    label l while (steps < maxSteps) {
      switch (st.dedupeOrder.peekFront()) {
        case (?(at, rid)) {
          if (now - at > limits.dedupeTtlNs or st.dedupe.size() > limits.maxDedupe) {
            ignore st.dedupeOrder.popFront();
            switch (st.dedupe.get(rid)) { case (?r) { if (r.at == at) st.dedupe.remove(rid) }; case null {} };
          } else break l;
        };
        case null break l;
      };
      steps += 1;
    };
  };

  public func dedupeRecord(st : State, requestId : Blob, now : Int, result : T.WriteResult) {
    if (requestId.size() == 0) return;
    st.dedupe.add(requestId, { at = now; result });
    st.dedupeOrder.pushBack((now, requestId));
  };
};
