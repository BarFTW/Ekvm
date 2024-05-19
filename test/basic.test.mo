import { test; suite }  "mo:test/async";
import Debug  "mo:base/Debug";
import Principal  "mo:base/Principal";
import Blob  "mo:base/Blob";
import EkvmModule "../src/Ekvm";
import Array  "mo:base/Array";
import Text "mo:base/Text";

import Cycles "mo:base/ExperimentalCycles";
import StableMemory "mo:base/ExperimentalStableMemory";

import Nat64 "mo:base/Nat64";
import Iter "mo:base/Iter";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import BTree "mo:stableheapbtreemap/BTree";
import BucketModule "../src/BucketModule";
import BucketActor "../src/BucketActor";
import Utils "../src/utils";
import Result "mo:base/Result";


let principals = Array.tabulate<Principal>(
    10,
    func(i) {
        Principal.fromBlob(Blob.fromArray([Nat8.fromNat(i)]));
    },
);
let principal = principals[0];


await suite("EkvmModule Test Suite", func() : async () {

    await test("Create Ekvm", func() : async () {
        let ekvm = EkvmModule.create(100, 40000, principal, principal, principal);
        assert(ekvm.indexPrincipal == principal);
        assert(ekvm.numBuckets == 100);
        assert(ekvm.minMem == 40000);
    });

    await test("Put data", func() : async () {
        let ekvm = EkvmModule.create(100, 40000, principal, principal, principal);
        ekvm.mockMode := true;
        // EkvmModule.setMockMode(Nat64.fromNat(1000000));
        let result = await EkvmModule.put(ekvm, "key", Blob.fromArray([1, 2, 3]), false);
        assert(result == true);
    });

    await test("Complex operation", func() : async () {
        let ekvm = EkvmModule.create(100, 40000, principal, principal, principal);
        ekvm.mockMode := true;
        Debug.print("----test----");
        let i = 3;
        ignore await EkvmModule.put(ekvm, "foo" # Nat.toText(i), Text.encodeUtf8("bar" # Nat.toText(i)), false);
        Debug.print("put done");

        let result = await EkvmModule.get(ekvm, "foo" # Nat.toText(i));
        Debug.print("get done" );
        // let value = Text.decodeUtf8(result);
        switch (result) {
            case (?blobValue) {
                let decodedValueOpt = Text.decodeUtf8(blobValue);
                switch (decodedValueOpt) {
                    case (?decodedValue) {
                        Debug.print("value: " # decodedValue);
                        assert(decodedValue == "bar" # Nat.toText(i));
                    };
                    case (_) {
                        Debug.print("error decoding text");
                        assert(false);
                    };
                };
            };
            case (_) { 
                Debug.print("error getting value");
                assert(false);
            };
        };

    });
});
