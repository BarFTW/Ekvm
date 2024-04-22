import Hash "mo:base/Hash";
import Text "mo:base/Text";
import Nat32 "mo:base/Nat32";
import Nat "mo:base/Nat";

module {
    public func key2Id(key: Text, numOfShards : Nat) : Nat32 {
        let hash = Text.hash(key);
        hash % Nat32.fromNat(numOfShards);
    };

    public func hashNat(n: Nat32) : Hash.Hash {
        Text.hash(Nat32.toText(n));
    };
};