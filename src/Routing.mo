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
};
