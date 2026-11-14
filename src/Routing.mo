/// Shard-side route check (DESIGN.md §4.2). The shard recomputes the slot from
/// the partition key with its own slotBits, so a client with a stale map gets
/// #wrongShard instead of being misrouted.
import Nat32 "mo:core/Nat32";
import Result "mo:core/Result";
import Hash "Hash";
import T "Types";

module {
  public func owns(a : T.Assignment, slot : Nat32) : Bool {
    let s = slot.toNat();
    for ((start, end_) in a.owned.values()) {
      if (s >= start and s < end_) return true;
    };
    false;
  };

  public func check(a : T.Assignment, route : T.Route, pk : Blob) : Result.Result<Nat32, T.Err> {
    let wrong = #err(#wrongShard { epoch = a.epoch; slotBits = a.slotBits });
    let bitsOk = route.slotBits == a.slotBits or (
      switch (a.acceptPrevSlotBits) { case (?p) p == route.slotBits; case null false }
    );
    if (not bitsOk) return wrong;
    let slot = Hash.slotOfKey(pk, a.slotBits);
    if (owns(a, slot)) #ok(slot) else wrong;
  };

  /// Route check for requests without a partition key (`ixScan`). Accepted:
  /// the shard's current (epoch, slotBits), or, during a doubling rollout,
  /// the previous map (epoch - 1, previous slotBits): doubling changes no
  /// ownership, so the slice is identical. Anything else is #wrongShard, so a
  /// page is never served from a stale slice (DESIGN.md §5.3).
  public func checkSlice(a : T.Assignment, route : T.Route) : Result.Result<(), T.Err> {
    let current = route.slotBits == a.slotBits and route.epoch == a.epoch;
    let prev = switch (a.acceptPrevSlotBits) {
      case (?p) p == route.slotBits and route.epoch + 1 == a.epoch;
      case null false;
    };
    if ((current or prev) and a.owned.size() > 0) #ok else #err(#wrongShard { epoch = a.epoch; slotBits = a.slotBits });
  };
};
