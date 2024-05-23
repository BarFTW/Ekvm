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
import Buffer "mo:base/Buffer";

import { JSON; Candid; CBOR } "mo:serde";
// import whiteLables "whiteLabels";
import Collection "../collectionsModule";


module {

    type Role = {
        #Owner;
        #Admin;
        #Member;
    };

    type IndexBy = {
        #Principal;
        #IdPart;
    };

    public type ManagedEntity = {
        ids: [Text];
        principals: [(Principal, Role)];
    };

    public class EntityManager(kv : EkvmModule.EKVDB, typeName : Text, idNames: [Text], indexes: [[(IndexBy, Nat)]]) = {
        var cols = Collection.init(kv);

        // public func createEntity(entity : ManagedEntity, objBlob : Blob) : async () {
        //     let principals = Array.append([entity.owner], entity.admins);

        //     let indexes : [Text] = Array.map<Principal, Text>(principals, func p = "wlId:" # entity.wlId # "-" # typeName # "Of:" # Principal.toText(p));
        //     ignore await cols.add(entity.id, "wlId:" # entity.wlId# "-"#typeName, Array.append(["all-" # typeName, "wlId:" # entity.wlId # "-all-" #typeName], indexes), objBlob);
        // };

        public func getDataKey(ids:[Text]): ?Text {
            if (ids.size() != idNames.size()) {
                Debug.print("ERROR: Missing id part"); 
                return null;
            };

            let dataKeyParts = Array.mapEntries<Text, Text>(ids, func (id, i) = idNames[i]#":"#id);
            Debug.print("DataKeyParts: " # debug_show(dataKeyParts));

            let dataKey = Array.foldLeft<Text, Text>(dataKeyParts, typeName, func (key, p) = key # "-" # p);
            Debug.print("DataKey: " # dataKey);
            ?dataKey;
        };

        public func getIdsFromKey(key: Text): [Text] {
            let partsIter = Text.split(key, #char '-');
            let parts = Iter.toArray<Text>(partsIter);
            let s : Nat = Array.size(parts);

            if (s != Array.size(idNames) + 1 or  s < 1) {
                Debug.trap("wrong key structure " # debug_show(s));
            };

            let buffer = Buffer.Buffer<Text>(s-1);
            
            var i=0;
            let b=Array.foldLeft<Text, Buffer.Buffer<Text>>(parts, buffer, func(buf, p) {
            
                let p2 = Iter.toArray(Text.split(p, #char ':'));
                if (i==0) {
                    if (p2[0] != typeName) {
                        Debug.trap("wrong type, expected " # typeName # " but got " # p2[0] );
                    };
                } else if (Array.size(p2) == 2) {
                    if (p2[0] != idNames[i-1]) {
                        Debug.trap("wrong key part, expected "# idNames[i-1] # " but got " # p2[0]);
                    };
                    buf.add(p2[1]);
                } else {
                    Debug.trap("wrong key, missing :");
                };
                i := i+1;
                buf;
                
            });

            Buffer.toArray(buffer);
        };

        private func handleIndex(index:[(IndexBy, Nat)], ids:[Text], principals: [(Principal, Role)]) : [Text] {
            func cartesianProduct(arrays: [[Text]]): [[Text]] {
        // Start with an array containing an empty array
                var result: [[Text]] = [[]];

                // Helper function to combine an array of lists with a list
                func combine(acc: [[Text]], array: [Text]): [[Text]] {
                    return Array.chain(acc, func(a: [Text]): [[Text]] {
                        return Array.map(array, func(b: Text): [Text] {
                             return Array.append(a, [b]);
                        });
                    });
                };

                // Combine each array in the input arrays
                for (array in arrays.vals()) {
                    result := combine(result, array);
                };

                return result;
            };


            func principalToText (tuple: (Principal, Role)) : Text {
                let (p, _) = tuple;
                "principal:"#Principal.toText(p);
            };

            Debug.print("index: ");
            let indexParts = Array.map<(IndexBy, Nat),[Text]>(index, func (indexBy, i) = 
                switch(indexBy) {
                    case (#Principal) {
                        Array.map<(Principal, Role), Text>(principals, principalToText);
                    };
                    case(#IdPart) {
                        [idNames[i]#":"#ids[i]];
                    };
                }
            );
            Debug.print("indexPart: "#debug_show(indexParts));
            let cartes = cartesianProduct(indexParts);
            Debug.print("cartes: "#debug_show(cartes));
            let indexKeys = Array.map<[Text],Text>(cartes, func a = Array.foldLeft<Text, Text>(a, typeName, func (key, p) = key # "-" # p));
            Debug.print("indexKey: " # debug_show(indexKeys));
            indexKeys;
        };

        public func createEntity(entity : ManagedEntity, objBlob : Blob) : async ?Text {
            let { ids; principals } = entity;
            // if (ids.size() != idNames.size()) {
            //     Debug.print("ERROR: Missing id part"); 
            //     return;
            // };

            // let dataKeyParts = Array.mapEntries<Text, Text>(ids, func (id, i) = idNames[i]#":"#id);
            // Debug.print("DataKeyParts: " # debug_show(dataKeyParts));

            // let dataKey = Array.foldLeft<Text, Text>(dataKeyParts, typeName, func (key, p) = key # "-" # p);
            // Debug.print("DataKey: " # dataKey);
            let dataKey = getDataKey(ids);
            // switch (dataKey) {
            //     case (?key) {};
            //     case (_) {
            //         return;
            //     };
            // };


            func _handleIndex(index:[(IndexBy, Nat)]) : [Text] {
                handleIndex(index, ids, entity.principals);
                // Debug.print("index: ");
                // let indexParts = Array.map<(IndexBy, Nat),[Text]>(index, func (indexBy, i) = 
                //     switch(indexBy) {
                //         case (#Principal) {
                //             Array.map<(Principal, Role), Text>(entity.principals, principalToText);
                //         };
                //         case(#IdPart) {
                //             [idNames[i]#":"#ids[i]];
                //         };
                //     }
                // );
                // Debug.print("indexPart: "#debug_show(indexParts));
                // let cartes = cartesianProduct(indexParts);
                // Debug.print("cartes: "#debug_show(cartes));
                // let indexKeys = Array.map<[Text],Text>(cartes, func a = Array.foldLeft<Text, Text>(a, typeName, func (key, p) = key # "-" # p));
                // Debug.print("indexKey: " # debug_show(indexKeys));
                // indexKeys;
            };
            let allIndexes = Array.map<[(IndexBy, Nat)],[Text]>(indexes, _handleIndex);

            // for (index in indexes.vals()) {
            //     Debug.print(debug_show(handleIndex(index)));
            // };
            
            Debug.print("All Indexes: "# debug_show(allIndexes));
            switch (dataKey) {
                case (?dk) {
                    ignore await cols.add(dk, Array.flatten<Text>(allIndexes), objBlob);
                };
                case (_) {
                    Debug.print("no data Key");
                };
            };
            dataKey;
            
            // let principals = Array.append([entity.owner], entity.admins);

            // let indexes : [Text] = Array.map<Principal, Text>(principals, func p = "wlId:" # entity.wlId # "-" # typeName # "Of:" # Principal.toText(p));
            // ignore await cols.add(entity.id, "wlId:" # entity.wlId# "-"#typeName, Array.append(["all-" # typeName, "wlId:" # entity.wlId # "-all-" #typeName], indexes), objBlob);
        };

        public func getEntityKeysByIndex(principal : ?Principal, ids:[Text], index:[(IndexBy, Nat)]) : async ?[Text] {
            let principals = switch (principal) {
                case (?p) {
                    [(p, #Admin)]
                };
                case (_) {
                    [];
                };
            };
            let indexP = handleIndex(index,ids,principals);
            Debug.print("index: "#debug_show(indexP));
            await cols.getKeys(indexP[0]);
            // ?["Not Yet"];

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


        // public func _get(id: Text, wlId: Text): async ?Blob {
        //     await cols.get("wlId:" #wlId # "-" # typeName, id);
        // };

        public func get(key: Text): async ?Blob {
            await cols.get(key);
        };

        public func getByIds(ids: [Text]): async ?Blob {
            let dataKey : ?Text = getDataKey(ids);
            switch (dataKey) {
                case (?key) {
                    await cols.get(key);
                };
                case (_) {
                    return null;
                };
            };
            
        };
    };

};
