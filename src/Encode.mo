/// Order-preserving key encodings (spec: docs/ENCODING.md).
///
/// Every encoder returns a byte string whose lexicographic (unsigned byte)
/// order equals the natural order of the input values. All encodings are
/// prefix-free, so they can be concatenated into composite keys (`tuple`)
/// and inverted for descending order (`desc`).
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Char "mo:core/Char";
import Int "mo:core/Int";
import Float "mo:core/Float";
import Int8 "mo:core/Int8";
import Int16 "mo:core/Int16";
import Int32 "mo:core/Int32";
import Int64 "mo:core/Int64";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat16 "mo:core/Nat16";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";

module {
  /// Big-endian, `n` least-significant bytes of `x`.
  func be(x : Nat64, n : Nat) : [Nat8] {
    Array.tabulate<Nat8>(
      n,
      func(i : Nat) : Nat8 {
        let shift = (8 * (n - 1 - i) : Nat).toNat64();
        ((x >> shift) & 0xff).toNat().toNat8();
      },
    );
  };

  /// Minimal big-endian bytes of an unbounded `Nat` (empty for 0).
  func natBytes(x : Nat) : [Nat8] {
    let out = List.empty<Nat8>();
    var v = x;
    while (v > 0) {
      out.add((v % 256).toNat8());
      v /= 256;
    };
    out.reverse().toArray();
  };

  func prefixed(head : Nat, body : [Nat8]) : Blob = [head.toNat8()].concat(body).toBlob();

  public func nat8(x : Nat8) : Blob = [x].toBlob();
  public func nat16(x : Nat16) : Blob = be(x.toNat().toNat64(), 2).toBlob();
  public func nat32(x : Nat32) : Blob = be(x.toNat().toNat64(), 4).toBlob();
  public func nat64(x : Nat64) : Blob = be(x, 8).toBlob();

  /// Two's complement with the sign bit flipped, big-endian.
  public func int8(x : Int8) : Blob = [x.toNat8() ^ 0x80].toBlob();
  public func int16(x : Int16) : Blob = be((x.toNat16() ^ 0x8000).toNat().toNat64(), 2).toBlob();
  public func int32(x : Int32) : Blob = be((x.toNat32() ^ 0x8000_0000).toNat().toNat64(), 4).toBlob();
  public func int64(x : Int64) : Blob = be(x.toNat64() ^ 0x8000_0000_0000_0000, 8).toBlob();

  /// Unbounded `Nat`: one length byte, then minimal big-endian bytes. Traps above 255 bytes.
  public func nat(x : Nat) : Blob {
    let b = natBytes(x);
    if (b.size() > 255) Runtime.trap("Encode.nat: value exceeds 255 bytes");
    prefixed(b.size(), b);
  };

  /// Unbounded `Int`: 0x80 for zero; 0x80+len ‖ |x| for positive;
  /// 0x80−len ‖ complement(|x|) for negative. Traps above 127 bytes.
  public func int(x : Int) : Blob {
    if (x == 0) return [0x80 : Nat8].toBlob();
    let b = natBytes(Int.abs(x));
    let len = b.size();
    if (len > 127) Runtime.trap("Encode.int: value exceeds 127 bytes");
    if (x > 0) prefixed(0x80 + len, b) else prefixed(0x80 - len, b.map<Nat8, Nat8>(func(c) = c ^ 0xff));
  };

  /// IEEE-754 bits of a Float, read from its Candid encoding
  /// ("DIDL" 0x00 0x01 0x72 + 8 bytes little-endian). Motoko has no
  /// bit-reinterpretation primitive for Float (moc 2.2.1, core 2.6.2).
  func floatBits(f : Float) : Nat64 {
    let c = (to_candid (f)).toArray();
    if (c.size() != 15) Runtime.trap("Encode.float: unexpected Candid encoding");
    var u : Nat64 = 0;
    var i = 14;
    while (i >= 7) {
      u := (u << 8) | c[i].toNat().toNat64();
      i -= 1;
    };
    u;
  };

  /// Float64: positive → sign bit set; negative → all bits complemented.
  /// −0.0 is normalised to +0.0. NaN traps (not orderable).
  public func float(f : Float) : Blob {
    if (f.isNaN()) Runtime.trap("Encode.float: NaN is not encodable");
    let u : Nat64 = if (f == 0.0) 0 else floatBits(f);
    let k = if (u >> 63 == 1) (u ^ 0xffff_ffff_ffff_ffff) else (u | 0x8000_0000_0000_0000);
    be(k, 8).toBlob();
  };

  public func bool(b : Bool) : Blob = [(if b 1 else 0) : Nat8].toBlob();

  /// Byte string: 0x00 escaped as 0x00 0xFF, terminated by 0x00 0x00.
  public func bytes(b : Blob) : Blob {
    let out = List.empty<Nat8>();
    for (c in b.values()) {
      out.add(c);
      if (c == 0) out.add(0xff : Nat8);
    };
    out.add(0 : Nat8);
    out.add(0 : Nat8);
    out.toArray().toBlob();
  };

  /// UTF-8 text, escaped like `bytes`. UTF-8 byte order = code point order.
  public func text(t : Text) : Blob = bytes(t.encodeUtf8());

  /// Descending order: complement every byte. Valid for any prefix-free encoding above.
  public func desc(b : Blob) : Blob = b.toArray().map<Nat8, Nat8>(func(c) = c ^ 0xff).toBlob();

  /// Composite key: concatenation of prefix-free parts.
  public func tuple(parts : [Blob]) : Blob = parts.map<Blob, [Nat8]>(Blob.toArray).flatten().toBlob();

  /// Lowercase hex, for tests and debugging.
  public func toHex(b : Blob) : Text {
    let digits : [Char] = "0123456789abcdef".chars().toArray();
    var t = "";
    for (c in b.values()) {
      t #= digits[(c / 16).toNat()].toText() # digits[(c % 16).toNat()].toText();
    };
    t;
  };

  /// Parse hex. Traps on invalid input.
  public func fromHex(h : Text) : Blob {
    func nib(c : Char) : Nat {
      let n = c.toNat32().toNat();
      if (n >= 48 and n <= 57) return n - 48;
      if (n >= 97 and n <= 102) return n - 87;
      if (n >= 65 and n <= 70) return n - 55;
      Runtime.trap("Encode.fromHex: invalid digit");
    };
    let cs : [Char] = h.chars().toArray();
    if (cs.size() % 2 != 0) Runtime.trap("Encode.fromHex: odd length");
    Array.tabulate<Nat8>(cs.size() / 2, func(i) = (nib(cs[2 * i]) * 16 + nib(cs[2 * i + 1])).toNat8()).toBlob();
  };
};
