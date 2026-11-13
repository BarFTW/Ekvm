import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Principal "mo:core/Principal";
import { suite; test } "mo:test";
import Hash "../src/Hash";
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
