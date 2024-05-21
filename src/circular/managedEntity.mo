import EkvmModule "../Ekvm";
import Principal "mo:base/Principal";
import Text "mo:base/Text";
import Debug "mo:base/Debug";

import Cycles "mo:base/ExperimentalCycles";
import StableMemory "mo:base/ExperimentalStableMemory";

import Nat64 "mo:base/Nat64";
import Iter "mo:base/Iter";
import Nat "mo:base/Nat";
import Result "mo:base/Result";
import Blob "mo:base/Blob";
import BTree "mo:stableheapbtreemap/BTree";
import BucketModule "../BucketModule";
import BucketActor "../BucketActor";
import Utils "../utils";
import Array "mo:base/Array";
import { JSON; Candid; CBOR } "mo:serde";
// import whiteLables "whiteLabels";
import Collection "../collectionsModule";

module {

    public type ManagedEntity = {
        wlId : Text;
        id : Text;
        name : Text;
        owner : Principal;
        admins : [Principal];
    };

    public class EntityManager(kv : EkvmModule.EKVDB, typeName : Text) = {
        //     createEntity: (entity : ManagedEntity, objBlob : Blob) -> async ();
        //     getEntityIdsFor(principal : ?Principal, wlId : ?Text) : async ?[Text];
        // };

        // public func init(kv: EkvmModule.EKVDB, typeName:Text): EntityManager {
            var cols = Collection.init(kv);
        //     object {
        public func createEntity(entity : ManagedEntity, objBlob : Blob) : async () {
            let principals = Array.append([entity.owner], entity.admins);
            let indexes : [Text] = Array.map<Principal, Text>(principals, func p = "wlId:" # entity.wlId # "-" # typeName # "Of:" # Principal.toText(p));
            ignore await cols.add(entity.id, "wlId:" # entity.wlId# "-"#typeName, Array.append(["all-" # typeName, "wlId:" # entity.wlId # "-all-" #typeName], indexes), objBlob);
        };

        public func getEntityIdsFor(principal : ?Principal, wlId : ?Text) : async ?[Text] {
            var key : Text = "";
            switch (principal, wlId) {

                case (?p, ?wlId) {
                    key := "wlId:" # wlId # "-" #typeName # "Of:" # Principal.toText(p);
                };

                case (?p, _) {
                    return null;
                };

                case (_, ?wlId) {
                    key := "wlId:" # wlId # "-all-" # typeName;
                };

                case (_, _) {
                    key := "all-" # typeName;
                };

            };
            await cols.getKeys(key);
        };


        public func get(id: Text, wlId: Text): async ?Blob {
            await cols.get("wlId:" #wlId # "-" # typeName, id);
        }
    };

};
