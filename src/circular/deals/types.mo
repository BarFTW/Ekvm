import Text "mo:base/Text";
import Blob "mo:base/Blob";

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
        public func set(Key: Text, val: Int): async Int {
            val;
        };

        public func inc(key:Text, val: Int): async Int {
            2;
        };
    };
    
    public type DealCalculator = {
        calculate: (event: Event, State: State) -> async [Reward];
    };

};