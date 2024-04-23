import Hash "mo:base/Hash";
import Text "mo:base/Text";
import Nat32 "mo:base/Nat32";
import Nat "mo:base/Nat";
import Order "mo:base/Order";

module {
    public func key2Id(key: Text, numOfShards : Nat) : Nat32 {
        let hash = Text.hash(key);
        hash % Nat32.fromNat(numOfShards);
    };

    public func hashNat(n: Nat32) : Hash.Hash {
        Text.hash(Nat32.toText(n));
    };

    public func nat32toOrder(v1: Nat32, v2: Nat32) : Order.Order {
        if (v1 > v2)
            return #greater;
        if (v2 > v1)
            return #less;
        return #equal;
    };

    public func textToOrder(t1: Text, t2: Text) : Order.Order {
        if (Text.greater(t1, t2))
            return #greater;
        if (Text.less(t1, t2))
            return #less;
        return #equal;
    };
};