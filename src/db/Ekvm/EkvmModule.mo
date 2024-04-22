import HashMap "mo:base/HashMap";
import Text "mo:base/Text";
import Principal "mo:base/Principal";
import Nat "mo:base/Nat";
import Blob "mo:base/Blob";
import Nat32 "mo:base/Nat32";
import Bool "mo:base/Bool";
import Debug "mo:base/Debug";

import Utils "../utils";
import BucketModule "../Bucket/BucketModule";
import BucketActor "../Bucket/BucketActor";

module {
    public type IndexManagmentMap = HashMap.HashMap<Nat32, Principal>;
    public type ActiveDataCanister = Principal;

    public type Ekvm = {
        var indexPrincipal: Principal;
        var numBuckets: Nat;
        var minMem: Nat;
        var indexMap: IndexManagmentMap;
        // var data: HashMap.HashMap<Text, Blob>;
        var bucket: BucketModule.Bucket;
        var localShards: HashMap.HashMap<Nat32, HashMap.HashMap<Text, Principal>>;
        var activeBucketCanister: Principal;
        var activeDataCanister: Principal;
    };

    private func whoManages(ekvm: Ekvm, id: Text) : ?Principal {
        let hash = Text.hash(id);
        Debug.print("size:" # debug_show (ekvm.numBuckets));
        let modulo = Nat32.toNat(hash) % ekvm.numBuckets;
        ekvm.indexMap.get(Nat32.fromNat(modulo));
    };

    public func get(ekvm: Ekvm, key: Text) : async ?Blob {
        switch(whoManages(ekvm, key)) {
            case(?shardPrincipal) { 
                if (Principal.equal(shardPrincipal, ekvm.indexPrincipal)) {
                    ekvm.bucket.data.get(key);
                }
                else {
                    let shardCanister = actor (Principal.toText(shardPrincipal)) : BucketActor.Bucket;
                    await shardCanister.get(key);
                };
             };
            case(_) { null };
        };
    };

    public func put(ekvm: Ekvm, key: Text, value: Blob) : async Bool {
        if (Principal.equal(ekvm.activeDataCanister, ekvm.indexPrincipal)) {
            ekvm.bucket.data.put(key, value);
        }
        else {
            let dataCanister = actor (Principal.toText(ekvm.activeDataCanister)) : BucketActor.Bucket;
            let hasMemory = await dataCanister.put(key, value);
            // todo: if no memory then scale
        };
        let id = Utils.key2Id(key, ekvm.numBuckets);
        let shardLocation = switch(ekvm.indexMap.get(id)) {
            case(?shardLocation) shardLocation;
            case(null) {
                ekvm.indexMap.put(id, ekvm.activeBucketCanister);
                ekvm.activeBucketCanister;
            };
        };
        if (Principal.equal(shardLocation, ekvm.indexPrincipal)) {
            let hasMemory = BucketModule.addKeyToShard(ekvm.bucket, key, ekvm.indexPrincipal);
            // todo: if no memory then scale
        }
        else {
            let shardCanister = actor (Principal.toText(shardLocation)) : BucketActor.Bucket;
            let hasMemory = await shardCanister.addKeyToShard(key, ekvm.activeDataCanister);
            // todo: if no memory then scale
        }
    };

    public func create(
        numBuckets: Nat,
        minMem: Nat,
        indexPrincipal: Principal,
        activeBucketCanister: Principal,
        activeDataCanister: Principal
    ) : Ekvm {
        let new :Ekvm = {
            var numBuckets = numBuckets;
            var minMem = minMem;
            var indexPrincipal = indexPrincipal;
            var activeBucketCanister = activeBucketCanister;
            var activeDataCanister = activeDataCanister;
            var indexMap = HashMap.HashMap<Nat32, Principal>(numBuckets, Nat32.equal, Utils.hashNat);
            var bucket = BucketModule.create(numBuckets);
            var localShards = HashMap.HashMap<Nat32, HashMap.HashMap<Text, Principal>>(0, Nat32.equal, Utils.hashNat);
        };
    };
};