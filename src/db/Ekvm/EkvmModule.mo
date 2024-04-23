import Text "mo:base/Text";
import Principal "mo:base/Principal";
import Nat "mo:base/Nat";
import Blob "mo:base/Blob";
import Nat32 "mo:base/Nat32";
import Bool "mo:base/Bool";

import BTree "mo:stableheapbtreemap/BTree";

import Utils "../utils";
import BucketModule "../Bucket/BucketModule";
import BucketActor "../Bucket/BucketActor";

module {
    public type IndexManagmentMap = BTree.BTree<Nat32, Principal>;
    public type ActiveDataCanister = Principal;

    public type Ekvm = {
        var indexPrincipal: Principal;
        var numBuckets: Nat;
        var minMem: Nat;
        var indexMap: IndexManagmentMap;
        var bucket: BucketModule.Bucket;
        var localShards: BTree.BTree<Nat32, BTree.BTree<Text, Principal>>;
        var activeBucketCanister: Principal;
        var activeDataCanister: Principal;
    };

    private func whoManages(ekvm: Ekvm, id: Text) : ?Principal {
        let hash = Text.hash(id);
        let modulo = Nat32.toNat(hash) % ekvm.numBuckets;
        BTree.get<Nat32, Principal>(ekvm.indexMap, Utils.nat32toOrder, Nat32.fromNat(modulo));
        
    };

    public func get(ekvm: Ekvm, key: Text) : async ?Blob {
        switch(whoManages(ekvm, key)) {
            case(?shardPrincipal) { 
                if (Principal.equal(shardPrincipal, ekvm.indexPrincipal)) {
                    BTree.get<Text, Blob>(ekvm.bucket.data, Utils.textToOrder, key);
                }
                else {
                    let shardCanister = actor (Principal.toText(shardPrincipal)) : BucketActor.Bucket;
                    await shardCanister.get(key);
                };
             };
            case(_) { null };
        };
    };

    private func allocateNewActiveBucketCanister(ekvm: Ekvm) : async () {
        let newCan = await BucketActor.Bucket(ekvm.numBuckets);
        ekvm.activeBucketCanister := Principal.fromActor(newCan);
    };

    private func allocateNewActiveDataCanister(ekvm: Ekvm) : async () {
        let newCan = await BucketActor.Bucket(ekvm.numBuckets);
        ekvm.activeDataCanister := Principal.fromActor(newCan);
    };

    private func putDataInNewCanister(ekvm: Ekvm, key: Text, value: Blob) : async Bool {
        await allocateNewActiveDataCanister(ekvm);
        let dataCanister = actor (Principal.toText(ekvm.activeDataCanister)) : BucketActor.Bucket;
        await dataCanister.put(key, value);
    };

    public func put(ekvm: Ekvm, key: Text, value: Blob) : async Bool {
        if (Principal.equal(ekvm.activeDataCanister, ekvm.indexPrincipal)) {
            // todo: check if local have enough memory
            let hasMemory = true;
            if (hasMemory) {
                ignore BTree.insert<Text, Blob>(ekvm.bucket.data, Utils.textToOrder, key, value);
            } else {
                ignore await putDataInNewCanister(ekvm, key, value);
            }
        }
        else {
            var dataCanister = actor (Principal.toText(ekvm.activeDataCanister)) : BucketActor.Bucket;
            let hasMemory = await dataCanister.put(key, value);
            if (not hasMemory) {
                ignore await putDataInNewCanister(ekvm, key, value);
            }
        };
        let id = Utils.key2Id(key, ekvm.numBuckets);

        let shardLocation = switch(BTree.get<Nat32, Principal>(ekvm.indexMap, Utils.nat32toOrder, id)) {
            case(?shardLocation) shardLocation;
            case(null) {
                ignore BTree.insert<Nat32, Principal>(ekvm.indexMap, Utils.nat32toOrder, id, ekvm.activeBucketCanister);
                ekvm.activeBucketCanister;
            };
        };
        if (Principal.equal(shardLocation, ekvm.indexPrincipal)) {
            let hasMemory = BucketModule.addKeyToShard(ekvm.bucket, key, ekvm.indexPrincipal);
            if (not hasMemory) {
                await putDataInNewCanister(ekvm, key, value);
            }
            else return true;
        }
        else {
            let shardCanister = actor (Principal.toText(shardLocation)) : BucketActor.Bucket;
            let hasMemory = await shardCanister.addKeyToShard(key, ekvm.activeDataCanister);
            if (not hasMemory) {
                await putDataInNewCanister(ekvm, key, value);
            }
            else return true;
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
            var indexMap = BTree.init<Nat32, Principal>(null);
            var bucket = BucketModule.create(numBuckets);
            var localShards = BTree.init<Nat32, BTree.BTree<Text, Principal>>(null);
        };
    };
};