/// Shared wire types (DESIGN.md §3). M0 defines routing types; data types are used from M1.
module {
  public type Key = { pk : Blob; sk : Blob };
  public type Entry = { key : Key; value : Blob; version : Nat64 };
  public type Cond = { #any; #absent; #version : Nat64 };
  public type WriteOp = {
    #put : { key : Key; value : Blob; cond : Cond };
    #delete : { key : Key; cond : Cond };
  };

  /// Map version and slot count the client routed with.
  public type Route = { epoch : Nat64; slotBits : Nat8 };

  public type Err = {
    #wrongShard : { epoch : Nat64; slotBits : Nat8 };
    #conflict : { key : Key; current : ?Nat64 };
    #unauthorized;
    #tooLarge;
    #migrating;
    #unknownIndex;
  };

  /// Range-compressed shard map (DESIGN.md §4.2).
  public type ShardMap = {
    epoch : Nat64;
    slotBits : Nat8;
    shards : [Principal];
    /// (first slot of range, shard index), sorted; a range ends where the next starts.
    ranges : [(Nat32, Nat16)];
    schemaVersion : Nat;
  };

  /// What the index pushes to one shard: its owned slot ranges as [start, end) in slot space.
  public type Assignment = {
    epoch : Nat64;
    slotBits : Nat8;
    /// Also accept requests routed with this slot count (set during a doubling rollout).
    acceptPrevSlotBits : ?Nat8;
    owned : [(Nat, Nat)];
  };
};
