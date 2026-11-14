import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Principal "mo:core/Principal";
import { suite; test } "mo:test";
import Hash "../src/Hash";
import MapLog "../src/MapLog";
import Routing "../src/Routing";
import SM "../src/ShardMap";
import T "../src/Types";
import V "Vectors";

let pids = [
  "aaaaa-aa", "rrkah-fqaaa-aaaaa-aaaaq-cai", "ryjl3-tyaaa-aaaaa-aaaba-cai", "r7inp-6aaaa-aaaaa-aaabq-cai",
  "rkp4c-7iaaa-aaaaa-aaaca-cai", "rno2w-sqaaa-aaaaa-aaacq-cai", "renrk-eyaaa-aaaaa-aaada-cai",
];
func shards(n : Nat) : [Principal] = Array.tabulate<Principal>(n, func(i) = Principal.fromText(pids[i % pids.size()]));

suite(
  "shard map",
  func() {
    test(
      "even split, lookups, doubling match vectors",
      func() {
        for (v in V.shardMap.values()) {
          let m = SM.even(shards(v.shards), v.slotBits, 1);
          assert SM.validate(m) == #ok;
          assert m.ranges == v.ranges;
          for ((slot, idx) in v.lookups.values()) assert SM.shardIndexOfSlot(m, slot) == idx;
          let d = SM.double(m);
          assert d.slotBits == v.slotBits + 1 and d.epoch == 2;
          assert d.ranges == v.doubled;
          assert d.ranges.size() == m.ranges.size();
          for ((slot, idx) in v.doubledLookups.values()) assert SM.shardIndexOfSlot(d, slot) == idx;
        };
      },
    );
    test(
      "doubling moves no key",
      func() {
        let m = SM.even(shards(5), 16, 1);
        let d = SM.double(m);
        for (i in ([0, 1, 2, 3, 99, 1000, 65535] : [Nat]).values()) {
          let pk : Blob = Array.tabulate<Nat8>(4, func(j) = ((i * 31 + j * 7) % 256).toNat8()).toBlob();
          assert SM.shardForKey(m, pk) == SM.shardForKey(d, pk);
        };
      },
    );
    test(
      "validate rejects bad maps",
      func() {
        let base = SM.even(shards(2), 4, 1);
        assert SM.validate({ base with slotBits = 0 }) != #ok;
        assert SM.validate({ base with ranges = [(1, 0)] }) != #ok;
        assert SM.validate({ base with ranges = [(0, 0), (0, 1)] }) != #ok;
        assert SM.validate({ base with ranges = [(0, 0), (16, 1)] }) != #ok;
        assert SM.validate({ base with ranges = [(0, 5)] }) != #ok;
      },
    );
    test(
      "canonical merges adjacent same-owner ranges",
      func() {
        let m = { SM.even(shards(2), 4, 1) with ranges = [(0, 0), (4, 0), (8, 1), (12, 1)] : [(Nat32, Nat16)] };
        assert SM.canonical(m).ranges == [(0, 0), (8, 1)];
      },
    );
    test(
      "owned ranges cover slot space exactly once",
      func() {
        let m = SM.even(shards(3), 8, 1);
        var total = 0;
        for (i in ([0, 1, 2] : [Nat16]).values()) for ((a, b) in SM.owned(m, i).values()) total += b - a;
        assert total == 256;
      },
    );
  },
);

suite(
  "routing",
  func() {
    let m = SM.even(shards(4), 16, 7);
    let pk : Blob = "\01\02\03";
    let slot = Hash.slotOfKey(pk, 16);
    let owner = SM.shardIndexOfSlot(m, slot);
    let other : Nat16 = (owner + 1) % 4;
    test(
      "owner accepts, others reject with #wrongShard",
      func() {
        assert Routing.check(SM.assignment(m, owner, null), { epoch = 7; slotBits = 16 }, pk) == #ok(slot);
        assert Routing.check(SM.assignment(m, other, null), { epoch = 7; slotBits = 16 }, pk) == #err(#wrongShard { epoch = 7; slotBits = 16 });
      },
    );
    test(
      "stale slotBits rejected after doubling, accepted during rollout",
      func() {
        let d = SM.double(m);
        let after : T.Assignment = SM.assignment(d, owner, null);
        let during : T.Assignment = SM.assignment(d, owner, ?16);
        assert Routing.check(after, { epoch = 7; slotBits = 16 }, pk) == #err(#wrongShard { epoch = 8; slotBits = 17 });
        assert Routing.check(during, { epoch = 7; slotBits = 16 }, pk) == #ok(Hash.slotOfKey(pk, 17));
        assert Routing.check(after, { epoch = 8; slotBits = 17 }, pk) == #ok(Hash.slotOfKey(pk, 17));
      },
    );
  },
);

// ---------------------------------------------------------------- M2: moves, change log, rollout

func ownerOfSlot(m : SM.ShardMap, s : Nat) : Nat16 = SM.shardIndexOfSlot(m, s.toNat32());

suite(
  "map changes and delta log",
  func() {
    test(
      "move reassigns exactly the moved slots and stays canonical",
      func() {
        let m = SM.even(shards(4), 4, 1); // 16 slots, 4 per shard
        let cases : [(Nat, Nat, Nat16)] = [(0, 1, 3), (3, 9, 0), (12, 16, 0), (0, 16, 2), (5, 6, 1), (4, 8, 1)];
        for ((a, b, s) in cases.values()) {
          let n = SM.move(m, a, b, s);
          assert SM.validate(n) == #ok and n.epoch == 2;
          assert SM.canonical(n).ranges == n.ranges;
          for (slot in Nat.range(0, 16)) {
            let expect = if (slot >= a and slot < b) s else ownerOfSlot(m, slot);
            assert ownerOfSlot(n, slot) == expect;
          };
        };
        // moving a range onto its owner only bumps the epoch
        assert SM.move(m, 4, 8, 1).ranges == m.ranges;
      },
    );
    test(
      "apply: double, move, addShard",
      func() {
        let m = SM.even(shards(2), 3, 1);
        let d = SM.apply(m, #double);
        assert d.slotBits == 4 and d.epoch == 2;
        let a = SM.apply(d, #addShard(Principal.fromText("aaaaa-aa")));
        assert a.shards.size() == 3 and a.epoch == 3 and a.ranges == d.ranges;
        let mv = SM.apply(a, #move { start = 0; end_ = 2; shard = 2 });
        assert ownerOfSlot(mv, 0) == 2 and ownerOfSlot(mv, 2) == 0 and mv.epoch == 4;
      },
    );
    test(
      "since: empty delta, delta chain, full outside the window or after reset",
      func() {
        let log = MapLog.new();
        var m = SM.even(shards(3), 8, 1);
        MapLog.reset(log, 1);
        let base = m;
        assert MapLog.since(log, m, 1) == #delta { from = 1; to = 1; changes = [] };
        let changes : [T.MapChange] = [#double, #move { start = 0; end_ = 10; shard = 2 }, #double];
        for (c in changes.values()) {
          m := SM.apply(m, c);
          MapLog.record(log, m.epoch, c, 256);
        };
        switch (MapLog.since(log, m, 1)) {
          case (#delta d) {
            assert d.from == 1 and d.to == 4 and d.changes.size() == 3;
            var r = base;
            for (c in d.changes.values()) r := SM.apply(r, c);
            assert SM.equal(r, m);
          };
          case (#full _) assert false;
        };
        assert MapLog.since(log, m, 0) == #full(m); // predates the reset
        assert MapLog.since(log, m, 9) == #full(m); // from the future
        // window cap: only the last 2 changes are kept
        let small = MapLog.new();
        MapLog.reset(small, 1);
        var m2 = base;
        for (c in changes.values()) { m2 := SM.apply(m2, c); MapLog.record(small, m2.epoch, c, 2) };
        assert MapLog.since(small, m2, 1) == #full(m2);
        switch (MapLog.since(small, m2, 2)) { case (#delta d) assert d.changes.size() == 2; case (#full _) assert false };
      },
    );
    test(
      "slice check accepts the previous map only during a doubling rollout",
      func() {
        let m = SM.even(shards(2), 8, 1);
        let d = SM.double(m);
        let during = SM.assignment(d, 0, ?8);
        let after = SM.assignment(d, 0, null);
        assert Routing.checkSlice(during, { epoch = 2; slotBits = 9 }) == #ok;
        assert Routing.checkSlice(during, { epoch = 1; slotBits = 8 }) == #ok;
        assert Routing.checkSlice(during, { epoch = 0; slotBits = 8 }) != #ok;
        assert Routing.checkSlice(after, { epoch = 1; slotBits = 8 }) == #err(#wrongShard { epoch = 2; slotBits = 9 });
        assert Routing.checkSlice(after, { epoch = 2; slotBits = 9 }) == #ok;
      },
    );
  },
);
