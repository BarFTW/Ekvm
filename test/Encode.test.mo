// @testmode wasi
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Debug "mo:core/Debug";
import Int "mo:core/Int";
import Int8 "mo:core/Int8";
import Int16 "mo:core/Int16";
import Int32 "mo:core/Int32";
import Int64 "mo:core/Int64";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat16 "mo:core/Nat16";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import { suite; test } "mo:test";
import E "../src/Encode";
import V "Vectors";

func check(label_ : Text, got : Blob, wantHex : Text) {
  let g = E.toHex(got);
  if (g != wantHex) {
    Debug.print("MISMATCH " # label_ # ": got " # g # " want " # wantHex);
    assert false;
  };
};

// Deterministic PRNG (xorshift64*) for property tests.
var seed : Nat64 = 0x9E37_79B9_7F4A_7C15;
func rnd() : Nat64 {
  seed ^= seed >> 12;
  seed ^= seed << 25;
  seed ^= seed >> 27;
  seed *% 0x2545_F491_4F6C_DD1D;
};

func sortedByBytes<T>(xs : [T], enc : T -> Blob, cmp : (T, T) -> { #less; #equal; #greater }) : Bool {
  // Value order and byte order must agree on every pair.
  for (i in Nat.range(0, xs.size())) {
    for (j in Nat.range(0, xs.size())) {
      let a = enc(xs[i]);
      let b = enc(xs[j]);
      let byBytes = Blob.compare(a, b);
      if (byBytes != cmp(xs[i], xs[j])) return false;
    };
  };
  true;
};

suite(
  "vectors",
  func() {
    test(
      "fixed-width Nat",
      func() {
        for ((t, v, h) in V.fixedNat.values()) {
          let got = switch t {
            case "nat8" E.nat8(v.toNat8());
            case "nat16" E.nat16(v.toNat16());
            case "nat32" E.nat32(v.toNat32());
            case _ E.nat64(v.toNat64());
          };
          check(t # " " # v.toText(), got, h);
        };
      },
    );
    test(
      "fixed-width Int",
      func() {
        for ((t, v, h) in V.fixedInt.values()) {
          let got = switch t {
            case "int8" E.int8(Int8.fromInt(v));
            case "int16" E.int16(Int16.fromInt(v));
            case "int32" E.int32(Int32.fromInt(v));
            case _ E.int64(Int64.fromInt(v));
          };
          check(t # " " # v.toText(), got, h);
        };
      },
    );
    test("nat", func() { for ((v, h) in V.nat.values()) check("nat " # v.toText(), E.nat(v), h) });
    test("int", func() { for ((v, h) in V.int.values()) check("int " # v.toText(), E.int(v), h) });
    test("float", func() { for ((v, h) in V.float().values()) check("float", E.float(v), h) });
    test("bool", func() { for ((v, h) in V.bool.values()) check("bool", E.bool(v), h) });
    test("text", func() { for ((v, h) in V.text.values()) check("text " # v, E.text(v), h) });
    test("bytes", func() { for ((v, h) in V.blob.values()) check("bytes " # v, E.bytes(E.fromHex(v)), h) });
    test("desc(text)", func() { for ((v, h) in V.descText.values()) check("desc " # v, E.desc(E.text(v)), h) });
    test("desc(int64)", func() { for ((v, h) in V.descInt64.values()) check("desc", E.desc(E.int64(Int64.fromInt(v))), h) });
    test(
      "tuple",
      func() {
        check("t1", E.tuple([E.text("a"), E.nat64(1)]), "610000" # "0000000000000001");
        check("t2", E.tuple([E.text("a\u{0}"), E.nat64(0)]), "6100ff0000" # "0000000000000000");
        check("t3", E.tuple([E.desc(E.float(1.5)), E.bytes(E.fromHex("00ff"))]), E.toHex(E.desc(E.float(1.5))) # "00ffff0000");
      },
    );
  },
);

suite(
  "order properties (random)",
  func() {
    test(
      "int64 byte order == value order",
      func() {
        let xs = Array.tabulate<Int64>(200, func(_) = Int64.fromNat64(rnd()));
        assert sortedByBytes<Int64>(xs, E.int64, Int64.compare);
      },
    );
    test(
      "nat (unbounded) byte order == value order",
      func() {
        let xs = Array.tabulate<Nat>(200, func(i) = rnd().toNat() * (if (i % 3 == 0) 2 ** 70 else 1) / (2 ** (i % 60)));
        assert sortedByBytes<Nat>(xs, E.nat, Nat.compare);
      },
    );
    test(
      "int (unbounded) byte order == value order",
      func() {
        let xs = Array.tabulate<Int>(200, func(i) { let m = rnd().toNat() / (2 ** (i % 60)); if (i % 2 == 0) m else -m });
        assert sortedByBytes<Int>(xs, E.int, Int.compare);
      },
    );
    test(
      "float byte order == value order",
      func() {
        let xs = Array.tabulate<Float>(200, func(i) { let v = Int64.fromNat64(rnd()).toInt().toFloat() / 1.0e9; if (i % 7 == 0) v * 1.0e300 else v });
        func fcmp(a : Float, b : Float) : { #less; #equal; #greater } = if (a < b) #less else if (a > b) #greater else #equal;
        assert sortedByBytes<Float>(xs, E.float, fcmp);
      },
    );
    test(
      "desc reverses order",
      func() {
        let xs = Array.tabulate<Int64>(100, func(_) = Int64.fromNat64(rnd()));
        func rev(a : Int64, b : Int64) : { #less; #equal; #greater } = Int64.compare(b, a);
        assert sortedByBytes<Int64>(xs, func(x) = E.desc(E.int64(x)), rev);
      },
    );
    test(
      "-0.0 encodes as +0.0",
      func() { assert E.float(-0.0) == E.float(0.0) },
    );
  },
);
