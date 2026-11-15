/// 32-bit key hash and slot derivation (DESIGN.md §4.1).
import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Runtime "mo:core/Runtime";
import Sha256 "mo:sha2/Sha256";

module {
  /// First 4 bytes of SHA-256(pk), big-endian.
  public func keyHash(pk : Blob) : Nat32 {
    let d = Sha256.fromBlob(#sha256, pk).toArray();
    func b(i : Nat) : Nat32 = d[i].toNat().toNat32();
    (b(0) << 24) | (b(1) << 16) | (b(2) << 8) | b(3);
  };

  /// Top `slotBits` bits of the hash. `slotBits` must be in 1..32.
  public func slotOf(h : Nat32, slotBits : Nat8) : Nat32 {
    if (slotBits < 1 or slotBits > 32) Runtime.trap("Hash.slotOf: slotBits must be 1..32");
    if (slotBits == 32) h else h >> (32 - slotBits.toNat() : Nat).toNat32();
  };

  public func slotOfKey(pk : Blob, slotBits : Nat8) : Nat32 = slotOf(keyHash(pk), slotBits);
};
