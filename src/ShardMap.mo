/// Pure functions over the range-compressed shard map (DESIGN.md §4.1–4.2).
import Array "mo:core/Array";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat16 "mo:core/Nat16";
import Nat32 "mo:core/Nat32";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Hash "Hash";
import T "Types";

module {
  public type ShardMap = T.ShardMap;

  public func slotCount(slotBits : Nat8) : Nat = 2 ** slotBits.toNat();

  /// Check structural invariants: 1 ≤ slotBits ≤ 32, ranges start at 0,
  /// strictly increasing, inside slot space, valid shard indexes.
  public func validate(m : ShardMap) : Result.Result<(), Text> {
    if (m.slotBits < 1 or m.slotBits > 32) return #err("slotBits out of range");
    if (m.ranges.size() == 0) return #err("no ranges");
    if (m.ranges[0].0 != 0) return #err("first range must start at slot 0");
    let total = slotCount(m.slotBits);
    var prev : ?Nat = null;
    for ((first, shard) in m.ranges.values()) {
      let f = first.toNat();
      if (f >= total) return #err("range start outside slot space");
      switch prev { case (?p) { if (f <= p) return #err("ranges not strictly increasing") }; case null {} };
      if (shard.toNat() >= m.shards.size()) return #err("shard index out of range");
      prev := ?f;
    };
    #ok;
  };

  /// Index of the range containing `slot` (binary search, O(log R)).
  /// Requires a valid map (ranges[0] starts at slot 0).
  public func rangeIndex(m : ShardMap, slot : Nat32) : Nat {
    var lo = 0;
    var hi = m.ranges.size(); // invariant: ranges[lo].first <= slot < ranges[hi].first
    while (lo + 1 < hi) {
      let mid = (lo + hi) / 2;
      if (m.ranges[mid].0 <= slot) lo := mid else hi := mid;
    };
    lo;
  };

  public func shardIndexOfSlot(m : ShardMap, slot : Nat32) : Nat16 = m.ranges[rangeIndex(m, slot)].1;

  public func shardForKey(m : ShardMap, pk : Blob) : Principal {
    m.shards[shardIndexOfSlot(m, Hash.slotOfKey(pk, m.slotBits)).toNat()];
  };

  /// Even contiguous split of the slot space over `shards`.
  public func even(shards : [Principal], slotBits : Nat8, epoch : Nat64) : ShardMap {
    let total = slotCount(slotBits);
    let n = shards.size();
    {
      epoch;
      slotBits;
      shards;
      ranges = Array.tabulate<(Nat32, Nat16)>(n, func(i) = ((i * total / n).toNat32(), i.toNat16()));
      schemaVersion = 0;
    };
  };

  /// Slot doubling: slotBits+1, every range start doubles. Same owners, same
  /// number of ranges, zero data movement; bumps epoch.
  public func double(m : ShardMap) : ShardMap {
    assert m.slotBits < 32;
    {
      m with
      epoch = m.epoch + 1;
      slotBits = m.slotBits + 1;
      ranges = m.ranges.map<(Nat32, Nat16), (Nat32, Nat16)>(func((f, s)) = (f * 2, s));
    };
  };

  /// Merge adjacent ranges with the same owner.
  public func canonical(m : ShardMap) : ShardMap {
    let out = List.empty<(Nat32, Nat16)>();
    for (r in m.ranges.values()) {
      switch (out.last()) {
        case (?(_, s)) { if (s != r.1) out.add(r) };
        case null { out.add(r) };
      };
    };
    { m with ranges = out.toArray() };
  };

  /// Slot ranges [start, end) owned by shard `idx`.
  public func owned(m : ShardMap, idx : Nat16) : [(Nat, Nat)] {
    let total = slotCount(m.slotBits);
    let out = List.empty<(Nat, Nat)>();
    let n = m.ranges.size();
    for (i in Nat.range(0, n)) {
      if (m.ranges[i].1 == idx) {
        let start = m.ranges[i].0.toNat();
        let end_ = if (i + 1 < n) m.ranges[i + 1].0.toNat() else total;
        out.add((start, end_));
      };
    };
    out.toArray();
  };

  public func assignment(m : ShardMap, idx : Nat16, acceptPrevSlotBits : ?Nat8) : T.Assignment {
    { epoch = m.epoch; slotBits = m.slotBits; acceptPrevSlotBits; owned = owned(m, idx) };
  };

  public func indexOfShard(m : ShardMap, p : Principal) : ?Nat16 {
    for (i in Nat.range(0, m.shards.size())) {
      if (Principal.equal(m.shards[i], p)) return ?i.toNat16();
    };
    null;
  };

  /// Reassign slots [start, end_) to shard table entry `shard`; bumps epoch.
  /// Result is canonical (adjacent same-owner ranges merged).
  public func move(m : ShardMap, start : Nat, end_ : Nat, shard : Nat16) : ShardMap {
    let total = slotCount(m.slotBits);
    assert start < end_ and end_ <= total and shard.toNat() < m.shards.size();
    let out = List.empty<(Nat32, Nat16)>();
    let n = m.ranges.size();
    var placed = false;
    for (i in Nat.range(0, n)) {
      let (f, s) = m.ranges[i];
      let a = f.toNat();
      let b = if (i + 1 < n) m.ranges[i + 1].0.toNat() else total;
      // part of [a, b) before start
      if (a < start) out.add((f, s));
      if (not placed and b > start) { out.add((start.toNat32(), shard)); placed := true };
      // part of [a, b) at or after end_
      if (b > end_) { out.add((Nat.max(a, end_).toNat32(), s)) };
    };
    // Keep only the first entry per start slot (a range split at `start` may add duplicates).
    let dedup = List.empty<(Nat32, Nat16)>();
    for (r in out.values()) {
      switch (dedup.last()) { case (?(f, _)) { if (f == r.0) { ignore dedup.removeLast() } }; case null {} };
      dedup.add(r);
    };
    canonical({ m with epoch = m.epoch + 1; ranges = dedup.toArray() });
  };

  /// Apply one logged change (DESIGN.md §4.2 delta fetch).
  public func apply(m : ShardMap, c : T.MapChange) : ShardMap {
    switch c {
      case (#double) double(m);
      case (#move { start; end_; shard }) move(m, start, end_, shard);
      case (#addShard p) { { m with epoch = m.epoch + 1; shards = m.shards.concat([p]) } };
    };
  };

  /// Equality of content (epoch, slotBits, shard table, ranges).
  public func equal(a : ShardMap, b : ShardMap) : Bool {
    a.epoch == b.epoch and a.slotBits == b.slotBits and a.shards == b.shards and a.ranges == b.ranges and a.schemaVersion == b.schemaVersion;
  };
};
