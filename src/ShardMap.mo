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
};
