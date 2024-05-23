import Text "mo:base/Text";
import Blob "mo:base/Blob";
import Debug "mo:base/Debug";

module {
    public type Reward = {
        amount: Int;
    };

    public type Event = {
        name: Text;
        amount: Int;
        count: Nat;
    };

    public type State = {
        get: (key:Text) -> async Int;
        set: (key: Text, val:Int) -> async Int;
        inc: (key: Text, val:Int) -> async Int;
    };

    public class DummyState() {
        public func get(key:Text): async Int {
            1;
        };
        public func set(key: Text, val: Int): async Int {
            Debug.print("setting key " # key # " to " # debug_show(val));
            val;
        };

        public func inc(key:Text, val: Int): async Int {
            Debug.print("incrementing key " # key # " by " # debug_show(val));
            2;
        };
    };

    public type DealCalculator = {
        calculate: (event: Event, State: State) -> async [Reward];
    };

};