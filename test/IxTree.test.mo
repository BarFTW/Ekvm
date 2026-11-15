import Array "mo:core/Array";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Order "mo:core/Order";
import { suite; test } "mo:test";
import Encode "../src/Encode";
import IxTree "../src/IxTree";
import T "../src/Types";

// Deterministic LCG.
var seed : Nat = 12345;
func rand(n : Nat) : Nat { seed := (seed * 6364136223846793005 + 1442695040888963407) % 18446744073709551616; (seed / 65536) % n };

func randBlob(maxLen : Nat, alphabet : Nat) : Blob {
  let len = rand(maxLen + 1);
  Array.tabulate<Nat8>(len, func _ = Nat8.fromNat(rand(alphabet))).toBlob();
};

func pos(ix : Blob, pk : Blob, sk : Blob) : T.IxPos = { ixKey = ix; key = { pk; sk } };

func randPos(mode : Nat) : T.IxPos {
  switch mode {
    // tiny alphabet incl. 0x00 and 0xff: lots of ties and escape cases
    case 0 pos(randBlob(4, 3), randBlob(3, 3), randBlob(2, 3));
    // numeric index keys with shared prefixes
    case 1 pos(Encode.nat64(Nat64.fromNat(rand(500))), Encode.text("u" # Nat.toText(rand(50))), randBlob(3, 256));
    case _ pos(randBlob(20, 256), randBlob(20, 256), randBlob(20, 256));
  };
};
func toList(it : { next : () -> ?T.IxPos }) : [T.IxPos] {
  let buf = List.empty<T.IxPos>();
  loop { switch (it.next()) { case (?k) buf.add(k); case null return buf.toArray() } };
};

func eqPos(a : T.IxPos, b : T.IxPos) : Bool = IxTree.compare(a, b) == #equal;

suite(
  "IxTree",
  func() {
    test(
      "prefix is monotone with compare",
      func() {
        for (mode in [0, 1, 2].values()) {
          var i = 0;
          while (i < 3000) {
            let a = randPos(mode);
            let b = randPos(mode);
            let (a1, a2) = IxTree.prefix(a);
            let (b1, b2) = IxTree.prefix(b);
            assert a1 < 72057594037927936 and a2 < 72057594037927936;
            let pc : Order.Order = if (a1 < b1) #less else if (a1 > b1) #greater else if (a2 < b2) #less else if (a2 > b2) #greater else #equal;
            switch (IxTree.compare(a, b), pc) {
              case (#less, #greater) assert false;
              case (#greater, #less) assert false;
              case (#equal, p) assert p == #equal;
              case _ {};
            };
            i += 1;
          };
        };
      },
    );
    test(
      "random add/remove matches core Map, incl. ordered iteration from bounds",
      func() {
        for ((mode, order) in [(0, 4), (1, 5), (2, 64), (1, 8)].values()) {
          let t = IxTree.emptyWithOrder(order);
          let ref = Map.empty<T.IxPos, ()>();
          var step = 0;
          while (step < 6000) {
            let k = randPos(mode);
            // grow for the first half, then churn with more removals
            if (rand(10) < (if (step < 3000) 8 else 4)) {
              let had = ref.containsKey(IxTree.compare, k);
              assert IxTree.add(t, k) == not had;
              ref.add(IxTree.compare, k, ());
            } else {
              // remove an existing key half the time
              let victim = if (rand(2) == 0 and ref.size() > 0) {
                switch (ref.entriesFrom(IxTree.compare, k).next()) { case (?(x, _)) x; case null k };
              } else k;
              let had = ref.containsKey(IxTree.compare, victim);
              assert IxTree.remove(t, victim) == had;
              ref.remove(IxTree.compare, victim);
            };
            assert IxTree.size(t) == ref.size();
            if (step % 500 == 0) {
              let all = toList(IxTree.entriesFrom(t, null));
              let exp = ref.keys().toArray();
              assert all.size() == exp.size();
              for (j in all.keys()) assert eqPos(all[j], exp[j]);
              let rev = toList(IxTree.reverseFrom(t, null));
              assert rev.size() == exp.size();
              for (j in rev.keys()) assert eqPos(rev[j], exp[exp.size() - 1 - j]);
            };
            if (step % 50 == 0) {
              let b = randPos(mode);
              let got = toList(IxTree.entriesFrom(t, ?b));
              let exp = ref.entriesFrom(IxTree.compare, b).toArray();
              assert got.size() == exp.size();
              for (j in got.keys()) assert eqPos(got[j], exp[j].0);
              let gotR = toList(IxTree.reverseFrom(t, ?b));
              let expR = ref.reverseEntriesFrom(IxTree.compare, b).toArray();
              assert gotR.size() == expR.size();
              for (j in gotR.keys()) assert eqPos(gotR[j], expR[j].0);
              assert IxTree.contains(t, b) == ref.containsKey(IxTree.compare, b);
            };
            step += 1;
          };
        };
      },
    );
  },
);
