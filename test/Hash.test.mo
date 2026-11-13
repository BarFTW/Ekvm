import { suite; test } "mo:test";
import E "../src/Encode";
import H "../src/Hash";
import V "Vectors";

suite(
  "key hash",
  func() {
    test(
      "SHA-256 prefix and slots match vectors",
      func() {
        for ((pkHex, h, slots) in V.hash.values()) {
          let pk = E.fromHex(pkHex);
          assert H.keyHash(pk) == h;
          for ((bits, slot) in slots.values()) {
            assert H.slotOf(h, bits) == slot;
            assert H.slotOfKey(pk, bits) == slot;
          };
        };
      },
    );
    test(
      "doubling: child slot = 2s or 2s+1",
      func() {
        for ((pkHex, h, _) in V.hash.values()) {
          for (bits in ([1, 7, 16, 31] : [Nat8]).values()) {
            let s = H.slotOf(h, bits);
            let c = H.slotOf(h, bits + 1);
            assert c == 2 * s or c == 2 * s + 1;
          };
          ignore pkHex;
        };
      },
    );
  },
);
