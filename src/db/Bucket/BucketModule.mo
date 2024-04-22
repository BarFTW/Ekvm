import Text "mo:base/Text";
import Principal "mo:base/Principal";
import HashMap "mo:base/HashMap";
import Nat32 "mo:base/Nat32";
import Nat "mo:base/Nat";
import Utils "../utils";

module {
    type Key = Text;
    type Value = Blob;
    public type DataLocation = Principal;
    public type BucketData = HashMap.HashMap<Text, Blob>;

    public type Bucket = {
        data: BucketData;
        numOfBuckets: Nat;
        localShards: HashMap.HashMap<Nat32, HashMap.HashMap<Text, Principal>>;
    };

    public func create(numOfBuckets: Nat) : Bucket {
        let new: Bucket = {
            data = HashMap.HashMap<Text, Blob>(0, Text.equal, Text.hash);
            numOfBuckets = numOfBuckets;
            localShards =HashMap.HashMap<Nat32, HashMap.HashMap<Text, Principal>>(0, Nat32.equal, Utils.hashNat);
        };
        return new;
    };

    public func get(b: Bucket, key: Key) : async ?Value {
        b.data.get(key);
    };

    public func put(b: Bucket, key: Key, value: Value) {
        b.data.put(key, value);
    };

    public func addKeyToShard(b: Bucket, key: Key, dataPrincipal: Principal) : Bool {
        let id = Utils.key2Id(key, b.numOfBuckets);
        switch(b.localShards.get(id)) {
            case(?shard) {
                shard.put(key, dataPrincipal);
                true;
            };
            case(null) {
                let shard = HashMap.HashMap<Text, Principal>(1, Text.equal, Text.hash);
                shard.put(key, dataPrincipal);
                b.localShards.put(id, shard);
                true;
            };
        };
    };

    public func whereIs(b: Bucket, key: Text) : ?DataLocation {
        let id = Utils.key2Id(key, b.numOfBuckets);
        switch(b.localShards.get(id)) {
            case (?shard) shard.get(key);
            case (_) { null };
        };
    };
};