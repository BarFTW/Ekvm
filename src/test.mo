import EkvmModule "Ekvm";
import Principal "mo:base/Principal";
import Text "mo:base/Text";
import Debug "mo:base/Debug";

import Cycles "mo:base/ExperimentalCycles";
import StableMemory "mo:base/ExperimentalStableMemory";

import Nat64 "mo:base/Nat64";
import Iter "mo:base/Iter";
import Nat "mo:base/Nat";
import Blob "mo:base/Blob";
import BTree "mo:stableheapbtreemap/BTree";
import BucketModule "BucketModule";
import BucketActor "BucketActor";
import Utils "utils";


actor class TestDBUser() = this {

    stable var db : ?EkvmModule.Ekvm = null;


    type MyObject = {
        id: Nat;
        name: Text;
        isActive: Bool;
        arr : [Text];
    };

    type TextArray = [Text];

    public func init() {
        let myObject: MyObject = {
            id = 42;
            name = "Motoko";
            isActive = true;
            arr = ["Hello", "World"];
        };

        let myArray = ["Goodbye","Cruel","World"];
        // Serialize the object to a blob using to_candid
        let blob: Blob = to_candid(myArray);
        Debug.print("the blob " # debug_show(blob));

        // Deserialize the blob back to an object using from_candid
        let deserializedObject: ?TextArray = from_candid  blob;
        Debug.print(debug_show(deserializedObject));


        Debug.print "----init----";
        let memoryUsage = StableMemory.stableVarQuery();
        let beforeSize = (await memoryUsage()).size;

        let myPrincipal = Principal.fromActor(this);
        db := ?EkvmModule.create(100, 40000, myPrincipal, myPrincipal, myPrincipal);
        let afterSize = (await memoryUsage()).size;

        Debug.print("init_afterSize - " # debug_show (afterSize));
        Debug.print("init_beforeSize - " # debug_show (beforeSize));
        Debug.print("init_diff - " # debug_show (afterSize - beforeSize));

        let available = Cycles.available();
        Debug.print("init_available_cycles: " # debug_show(available));
        let balance = Cycles.balance();
        Debug.print("init_cycles_balance: " # debug_show(balance));
    };

    public func test() : async ?Text {
        let memoryUsage = StableMemory.stableVarQuery();
        switch(db) {
            case(?ekvm) { 
                Debug.print "----test----";
        let beforeSize = (await memoryUsage()).size;
        var afterSize: Nat64 = 0;

                for (i in Iter.range(1, 1200)) {
                    if (i % 100 == 0) {
                        switch (await EkvmModule.get(ekvm, "foo" # Nat.toText(i-99))) {
                            case (?foo)
                                Debug.print("\nfoo" # debug_show (i-99) # " - " # debug_show (foo));
                            case (_) { 
                                Debug.print("Not found (foo)");
                             };
                        };
                        afterSize := (await memoryUsage()).size;
                        Debug.print("\ni - " # Nat.toText(i) # "; afterSize - " # Nat64.toText(afterSize));
                    };
                    ignore await EkvmModule.put(ekvm, "foo" # Nat.toText(i), Text.encodeUtf8("bar" # Nat.toText(i)), false);
                };

        afterSize := (await memoryUsage()).size;

        Debug.print("\ntest_afterSize - " # debug_show (afterSize));
        Debug.print("\ntest_beforeSize - " # debug_show (beforeSize));
        Debug.print("\ntest_diff - " # debug_show (afterSize - beforeSize));

        return ?"Done";

                // switch(await EkvmModule.get(db, "foo")) {
                //     case (?a) {
                //         return Text.decodeUtf8(a);
                //         switch(await EkvmModule.get(db, "hello")) {
                //             case(?b) { 
                //                 switch(await EkvmModule.get(db, "bla")) {
                //                     case(?c) { 
                //                         return Text.decodeUtf8(a) # "_" # Text.decodeUtf8(b) # "_" # Text.decodeUtf8(c);
                //                      };
                //                     case(null) { null };
                //                 };
                //              };
                //             case(null) { null };
                //         };
                //     };
                //     case (_) { null };
                // }
            };
            case(_) {
                Debug.print "no db";
                null
            };
        };
    };

    public func get(k: Text) : async ?Text {
        switch(db) {
            case(?ekvm) { 
                switch (await EkvmModule.get(ekvm, k)) {
                    case (?v) Text.decodeUtf8(v);
                    case (_) null;
                };
            };
            case(_) { Debug.print (debug_show(" can't get" # debug_show(k))); null; };
        };
    };

    public func whereIs2(k: Text) : async ?Principal {
        Debug.print("whereId_1");
        switch(db) {
            case(?ekvm) { 
                Debug.print("whereId_2");
                switch(EkvmModule.whoManages(ekvm, k)) {
                    case(?can) {
                        Debug.print("Shard location: " # debug_show can);
                        if (Principal.equal(can, ekvm.indexPrincipal)) {
                            let id = Utils.key2Id(k, ekvm.bucket.numOfBuckets);
                            switch(BTree.get<Nat32, BTree.BTree<Text, Principal>>(ekvm.bucket.localShards, Utils.nat32toOrder, id)) {
                                case (?shard) 
                                    BTree.get<Text, Principal>(shard, Utils.textToOrder, k);
                                case (_) { null };
                            };
                        }
                        else {
                            let shard = actor (Principal.toText(can)) : BucketActor.Bucket;
                            switch(await shard.whereIs(k)) {
                                case(?location) {
                                    Debug.print("Data at Principal: " # debug_show location);
                                    ?location;
                                };
                                case (_) { null; };
                            };
                        };
                     };
                    case(_) { null };
                };
            };
            case(_) { null; };
        };
    };

    public func activeDataCanister() : async ?Principal {
        switch(db) {
            case(?ekvm) { ?(ekvm.activeDataCanister); };
            case(_) { null; };
        };
    };

    public func put(k: Text, v: Text, forceExternal: Bool) : async Bool {
        switch(db) {
            case(?ekvm) { await EkvmModule.put(ekvm, k, Text.encodeUtf8(v), forceExternal) };
            case(_) { Debug.print (debug_show(" can't put" # debug_show(k))); false; };
        };
    };
};