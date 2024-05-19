import EkvmModule "../Ekvm";
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
import BucketModule "../BucketModule";
import BucketActor "../BucketActor";
import Utils "../utils";
import Array "mo:base/Array";
import { JSON; Candid; CBOR } "mo:serde";

actor {
    stable var db : ?EkvmModule.Ekvm = null;

    type TextArray = [Text];


    public shared (msg) func init() {
        let myPrincipal = msg.caller;
        db := ?EkvmModule.create(100, 40000, myPrincipal, myPrincipal, myPrincipal);
    };


    public func createWhiteLabel(id : Text, name : Text) : async Bool {
        Debug.print("Creating white label with name: " # name # " and id: " # id);
        switch (db) {
            case (?ekvm) {
                ignore await EkvmModule.put(ekvm, "whiteLabel:" # id, Text.encodeUtf8(name), false);
                switch (await EkvmModule.get(ekvm, "whiteLabelKeys")) {
                    case (?keysBlob) {
                        let keys : ?TextArray = from_candid  keysBlob;
                        Debug.print("the keys: " # debug_show(keys) );
                        switch (keys) {
                            case (?keysArray) {
                                let newKeys = Array.append(keysArray, [id]);
                                 let keysArrayBlob: Blob = to_candid(newKeys);
                                ignore await EkvmModule.put(ekvm, "whiteLabelKeys", keysArrayBlob, false);
                                return true;
                            };
                            case (_) {
                                // Handle the case where getting the keys failed
                                Debug.print("Failed to get whiteLabelKeys");
                                let keysArray : TextArray = [id];
                                 let keysArrayBlob: Blob = to_candid(keysArray);
                                ignore await EkvmModule.put(ekvm, "whiteLabelKeys", keysArrayBlob, false);
                                return true;
                            };
                        };
                    };
                    case (_) {
                        // Handle the case where getting the keys failed
                        Debug.print("Failed to get whiteLabelKeys");
                        let keysArray : TextArray = [id];
                        let keysArrayBlob = to_candid (keysArray);
                        await EkvmModule.put(ekvm, "whiteLabelKeys", keysArrayBlob, false);
                    };
                };
            };
            case (_) {
                Debug.print("not initialized!");
                return false;
            };
        };
    };

};
