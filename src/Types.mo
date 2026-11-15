/// Shared wire types (DESIGN.md §3).
import Result "mo:core/Result";

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

  public type WriteResult = Result.Result<[Nat64], Err>;
  public type WriteReq = { route : Route; requestId : Blob; ops : [WriteOp] };

  /// Range bound. For `scan` it compares sort keys exactly; for `ixScan` it is a
  /// prefix bound on encoded index keys (see ENCODING.md "Index range bounds").
  public type Bound = { #incl : Blob; #excl : Blob; #unbounded };

  public type GetReq = { route : Route; keys : [Key] };
  public type ScanReq = { route : Route; pk : Blob; from : Bound; to : Bound; limit : Nat; reverse : Bool };
  /// `next` is the last returned sort key when more rows may follow; resume with
  /// `from = #excl next` (or `to = #excl next` when `reverse`).
  public type ScanPage = { entries : [Entry]; next : ?Blob };

  public type IxScanReq = {
    route : Route;
    index : Nat16;
    from : Bound;
    to : Bound;
    /// Exclusive resume position: the last row's (ixKey, key).
    after : ?IxPos;
    limit : Nat;
    reverse : Bool;
    withValues : Bool;
  };
  /// Position in an index. Rows are totally ordered by (ixKey, pk, sk),
  /// compared component-wise as unsigned bytes.
  public type IxPos = { ixKey : Blob; key : Key };
  public type IxRow = { ixKey : Blob; key : Key; version : Nat64; value : ?Blob };
  public type IxPage = { rows : [IxRow]; more : Bool };

  public type Readers = { #public_; #allow : [Principal] };
  /// Versioned allowlist pushed from the index to every shard (DESIGN.md §7).
  public type Access = { version : Nat64; writers : [Principal]; readers : Readers };

  /// Range-compressed shard map (DESIGN.md §4.2).
  public type ShardMap = {
    epoch : Nat64;
    slotBits : Nat8;
    shards : [Principal];
    /// (first slot of range, shard index), sorted; a range ends where the next starts.
    ranges : [(Nat32, Nat16)];
    schemaVersion : Nat;
  };

  /// One shard-map change, as logged by the index for delta fetches
  /// (DESIGN.md §4.2). Each change bumps the epoch by one.
  public type MapChange = {
    /// slotBits + 1, every range start doubles (zero data movement).
    #double;
    /// Slots [start, end_) now belong to shard table entry `shard`.
    #move : { start : Nat; end_ : Nat; shard : Nat16 };
    /// Append a principal to the shard table (owns nothing yet).
    #addShard : Principal;
  };

  public type MapSince = {
    /// Apply `changes` in order to a map at epoch `from` to reach epoch `to`.
    #delta : { from : Nat64; to : Nat64; changes : [MapChange] };
    #full : ShardMap;
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
