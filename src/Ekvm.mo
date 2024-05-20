import Text "mo:base/Text";
import Principal "mo:base/Principal";
import Nat "mo:base/Nat";
import Blob "mo:base/Blob";
import Nat32 "mo:base/Nat32";
import Nat64 "mo:base/Nat64";
import Bool "mo:base/Bool";

import Cycles "mo:base/ExperimentalCycles";
import Debug "mo:base/Debug";

import BTree "mo:stableheapbtreemap/BTree";

import Utils "utils";
import BucketModule "BucketModule";
import BucketActor "BucketActor";

module {
    public type IndexManagmentMap = BTree.BTree<Nat32, Principal>;
    public type ActiveDataCanister = Principal;

    public type Ekvm = {
        var indexPrincipal: Principal;
        var numBuckets: Nat;
        var minMem: Nat64;
        var indexMap: IndexManagmentMap;
        var bucket: BucketModule.Bucket;
        var localShards: BTree.BTree<Nat32, BTree.BTree<Text, Principal>>;
        var activeBucketCanister: Principal;
        var activeDataCanister: Principal;
        var mockMode: Bool;
        var mockMem: Nat64;
    };


    public type EKVDB = {
        whoManages: (key:Text) -> ?Principal;
        get: (key:Text) -> async ?Blob;
        put: (key:Text, value: Blob, forceNewExternal: Bool) -> async Bool;
    };

// should be private
    public func _whoManages(ekvm: Ekvm, key: Text) : ?Principal {
        let id = Utils.key2Id(key, ekvm.numBuckets);
        BTree.get<Nat32, Principal>(ekvm.indexMap, Utils.nat32toOrder, id);
    };

    public func _get(ekvm: Ekvm, key: Text) : async ?Blob {
        switch(_whoManages(ekvm, key)) {
            case(?shardLocation) { 
                if (Principal.equal(shardLocation, ekvm.indexPrincipal)) {
                    Debug.print("Local shard");
                    switch(BucketModule.whereIs(ekvm.bucket, key)) {
                        case(?dataLocation) { 
                            if (Principal.equal(dataLocation, ekvm.indexPrincipal)) {
                                Debug.print("Local data");
                                return BTree.get<Text, Blob>(ekvm.bucket.data, Utils.textToOrder, key);
                            }
                            else {
                                Debug.print("External data");
                                let dataCanister = actor (Principal.toText(dataLocation)) : BucketActor.Bucket;
                                return await dataCanister.get(key);
                            }
                         };
                        case(_) { null; };
                    };
                }
                else {
                    Debug.print("External shard");
                    let shardCanister = actor (Principal.toText(shardLocation)) : BucketActor.Bucket;
                    Cycles.add(15000000000);
                    switch(await shardCanister.whereIs(key)) {
                        case(?dataLocation) {
                            Debug.print("data location: " # debug_show (dataLocation));
                            if (Principal.equal(dataLocation, ekvm.indexPrincipal)) {
                                return await BucketModule.get(ekvm.bucket, key);
                            }
                            else {
                                let dataCanister = actor (Principal.toText(dataLocation)) : BucketActor.Bucket;
                                return await dataCanister.get(key);
                            }
                         };
                        case(_) { null; };
                    };
                };
             };
            case(_) { null };
        };
    };

    private func allocateNewActiveBucketCanister(ekvm: Ekvm) : async BucketActor.Bucket {
        Debug.print(debug_show ("creating new active bucket canister..."));
        Cycles.add(15000000000);
        let newCan = await BucketActor.Bucket(ekvm.numBuckets);
        ekvm.activeBucketCanister := Principal.fromActor(newCan);
        return newCan;
    };

    private func putBucketInNewCanister(ekvm: Ekvm, key: Text, value: Blob) : async Bool {
        Debug.print(debug_show ("not enough memory left..."));
        let bucketCanister = await allocateNewActiveBucketCanister(ekvm);
        Cycles.add(15000000000);
        await bucketCanister.put(key, value);
    };

    private func allocateNewActiveDataCanister(ekvm: Ekvm) : async BucketActor.Bucket {
        Debug.print(debug_show ("creating new active data canister..."));
        Cycles.add(15000000000);
        let newCan = await BucketActor.Bucket(ekvm.numBuckets);
        ekvm.activeDataCanister := Principal.fromActor(newCan);
        Debug.print("New Active data canister: " # debug_show (ekvm.activeDataCanister));
        return newCan;
    };

    private func putDataInNewCanister(ekvm: Ekvm, key: Text, value: Blob) : async Principal {
        Debug.print(debug_show ("not enough memory left..."));
        let bucketActor = await allocateNewActiveDataCanister(ekvm);
        Cycles.add(15000000000);
        ignore await bucketActor.put(key, value);
        Principal.fromActor(bucketActor);
    };

    public func _put(ekvm: Ekvm, key: Text, value: Blob, forceNewExternal: Bool) : async Bool {
        var activeDataCanister = ekvm.activeDataCanister;
        // put data in active data canister
        if (not forceNewExternal and Principal.equal(activeDataCanister, ekvm.indexPrincipal)) {
            // internal canister
            Debug.print("Ekvm.put() - Internal");
            // has memory?
            if (await Utils.checkMem(ekvm.bucket.threshold, ekvm.mockMode, Nat64.fromNat(0))) {
                // put to local data
                Debug.print("Insert to local Map.");
                ignore BTree.insert<Text, Blob>(ekvm.bucket.data, Utils.textToOrder, key, value);
            } else {
                // put to external data
                activeDataCanister := await putDataInNewCanister(ekvm, key, value);
            };

        }
        else if (forceNewExternal) {
            // test new external canister
            Debug.print("Ekvm.put() - Test Externral");
            Cycles.add(15000000000);
            activeDataCanister := await putDataInNewCanister(ekvm, key, value);
        }
        else {
            // external canister
            Debug.print("Ekvm.put() - Externral-1");
            var dataCanister = actor (Principal.toText(activeDataCanister)) : BucketActor.Bucket;
            Debug.print("Ekvm.put() - Externral-2");
            Cycles.add(15000000000);
            Debug.print("put to another canister: " # debug_show(Principal.toText(activeDataCanister)));
            let hasMemory : Bool = await dataCanister.put(key, value);
            if (not hasMemory) {
                activeDataCanister := await putDataInNewCanister(ekvm, key, value);
            }
        };

        // set data location and shard manager
        let shardLocation = switch(_whoManages(ekvm, key)) {
            case(?shardLocation) shardLocation;
            case(_) {
                let id : Nat32 = Utils.key2Id(key, ekvm.numBuckets);
                ignore BTree.insert<Nat32, Principal>(ekvm.indexMap, Utils.nat32toOrder, id, ekvm.activeBucketCanister);
                ekvm.activeBucketCanister;
            };
        };

        if (Principal.equal(shardLocation, ekvm.indexPrincipal)) {
            let hasMemory = 
                await BucketModule.addKeyToShard(ekvm.bucket, key, activeDataCanister);
            
        }
        else {
            Debug.print("external shard canister");
            let shardCanister = actor (Principal.toText(shardLocation)) : BucketActor.Bucket;
            Cycles.add(15000000000);
            let hasMemory =
                await shardCanister.addKeyToShard(key, activeDataCanister);
        };
    };

    public func getDB(state: ?Ekvm) : EKVDB {
        switch (state) {
            case (?s) {
                object {
                    public func whoManages(key:Text) : ?Principal {
                        _whoManages(s, key);
                    };

                    public func get(key: Text) : async ?Blob {
                        await _get(s, key);
                    };

                    public func  put(key:Text, value: Blob, forceNewExternal: Bool) : async Bool {
                        await _put(s, key, value, forceNewExternal);
                    };
                };
            };
            case (_) {
                object {
                    public func whoManages(key:Text) : ?Principal {
                        Debug.print("not initialized");
                        null;
                    };

                    public func get(key: Text) : async ?Blob {
                        Debug.print("not initialized");
                        null;
                    };

                    public func  put(key:Text, value: Blob, forceNewExternal: Bool) : async Bool {
                        Debug.print("not initialized");
                        false;
                    };

                };
            };
        };
    };


    public func create(
        numBuckets: Nat,
        minMem: Nat64,
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
            var bucket = BucketModule.create(numBuckets, ?minMem);
            var localShards = BTree.init<Nat32, BTree.BTree<Text, Principal>>(null);
            var mockMode = false;
            var mockMem = Nat64.fromNat(0);
        };
    };
};