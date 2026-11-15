/// Bounded log of shard-map changes kept by the index, so clients with a
/// recent cached map fetch only the changes since their epoch (DESIGN.md §4.2).
import Iter "mo:core/Iter";
import Queue "mo:core/Queue";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import T "Types";

module {
  /// `entries[i]` took the map from epoch `epoch - 1` to `epoch`.
  public type Log = {
    entries : Queue.Queue<{ epoch : Nat64; change : T.MapChange }>;
    /// Oldest epoch a delta can start from (a map reset, e.g. initial
    /// registration, starts a new base).
    var base : Nat64;
  };

  public let defaultCap = 256;

  public func new() : Log = { entries = Queue.empty(); var base = 0 };

  /// A full replacement (registration): older clients must refetch.
  public func size(log : Log) : Nat = log.entries.size();

  public func reset(log : Log, epoch : Nat64) {
    log.entries.clear();
    log.base := epoch;
  };

  public func record(log : Log, epoch : Nat64, change : T.MapChange, cap : Nat) {
    log.entries.pushBack({ epoch; change });
    while (log.entries.size() > cap) {
      switch (log.entries.popFront()) { case (?e) log.base := e.epoch; case null {} };
    };
  };

  /// Changes since `from`, or the full map if `from` is outside the window.
  public func since(log : Log, current : T.ShardMap, from : Nat64) : T.MapSince {
    if (from == current.epoch) return #delta { from; to = from; changes = [] };
    if (from < log.base or from > current.epoch) return #full(current);
    let changes = log.entries.values().filter(func(e : { epoch : Nat64; change : T.MapChange }) : Bool = e.epoch > from).map<{ epoch : Nat64; change : T.MapChange }, T.MapChange>(func e = e.change).toArray();
    if (changes.size().toNat64() != current.epoch - from) return #full(current);
    #delta { from; to = current.epoch; changes };
  };
};
