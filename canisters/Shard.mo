/// Ekvm shard canister: M0 skeleton (routing only; data operations arrive in M1).
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Runtime "mo:core/Runtime";
import Routing "../src/Routing";
import T "../src/Types";

actor class Shard(init : { index : Principal }) {
  let index : Principal = init.index;
  var assignment : T.Assignment = { epoch = 0; slotBits = 16; acceptPrevSlotBits = null; owned = [] };

  /// Index pushes this shard's slot ranges. Only the index may call it.
  public shared ({ caller }) func assign(a : T.Assignment) : async () {
    if (not Principal.equal(caller, index)) Runtime.trap("unauthorized");
    if (a.slotBits < 1 or a.slotBits > 32) Runtime.trap("invalid slotBits");
    assignment := a;
  };

  /// Route check exposed for tests and clients: the slot this shard would
  /// serve `pk` from, or #wrongShard.
  public query func routeCheck(route : T.Route, pk : Blob) : async Result.Result<Nat32, T.Err> {
    Routing.check(assignment, route, pk);
  };

  public query func version() : async Text { "ekvm-shard/0.0.1 (M0)" };

  public query func status() : async { index : Principal; assignment : T.Assignment } {
    { index; assignment };
  };
};
