import Text "mo:base/Text";
import Principal "mo:base/Principal";
import BTree "mo:stableheapbtreemap/BTree";

import Nat32 "mo:base/Nat32";
import Nat "mo:base/Nat";
import Utils "../utils";

module {
    type Key = Text;
    type Value = Blob;
    public type DataLocation = Principal;
    public type BucketData = BTree.BTree<Text, Blob>;

    public type Bucket = {
        data: BucketData;
        numOfBuckets: Nat;
        localShards: BTree.BTree<Nat32, BTree.BTree<Key, DataLocation>>;
    };

    public func create(numOfBuckets: Nat) : Bucket {
        let new: Bucket = {
            data = BTree.init<Text, Blob>(null);
            numOfBuckets = numOfBuckets;
            localShards =BTree.init<Nat32, BTree.BTree<Text, Principal>>(null);
        };
        return new;
    };

    public func get(b: Bucket, key: Key) : async ?Value {
        BTree.get<Key, Value>(b.data, Utils.textToOrder, key);
    };

    public func put(b: Bucket, key: Key, value: Value) : async Bool {
        ignore BTree.insert<Key, Value>(b.data, Utils.textToOrder, key, value);
        true;
    };

    public func addKeyToShard(b: Bucket, key: Key, dataPrincipal: Principal) : Bool {
        let id = Utils.key2Id(key, b.numOfBuckets);
        switch(BTree.get<Nat32, BTree.BTree<Text, Principal>>(b.localShards, Utils.nat32toOrder, id)) {
            case(?shard) {
                ignore BTree.insert<Text, Principal>(shard, Utils.textToOrder, key, dataPrincipal);
                return true;
            };
            case(null) {
                let shard = BTree.init<Text, Principal>(null);
                ignore BTree.insert<Text, Principal>(shard, Utils.textToOrder, key, dataPrincipal);
                ignore BTree.insert<Nat32, BTree.BTree<Text, Principal>>(b.localShards, Utils.nat32toOrder, id, shard);
                return true;
            };
        };
        return false;
    };

    public func whereIs(b: Bucket, key: Key) : ?DataLocation {
        let id = Utils.key2Id(key, b.numOfBuckets);
        switch(BTree.get<Nat32, BTree.BTree<Key, DataLocation>>(b.localShards, Utils.nat32toOrder, id)) {
            case (?shard) 
                BTree.get<Key, DataLocation>(shard, Utils.textToOrder, key);
            case (_) { null };
        };
    };
};