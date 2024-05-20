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
import { add; get; getKeys} "../collectionsModule";
import whiteLables "whiteLabels";

actor {
    stable var db : ?EkvmModule.Ekvm = null;
    
     var kv : EkvmModule.EKVDB = EkvmModule.getDB(db);




    stable var gs : ?whiteLables.ComplexState = null;
    var greeter: whiteLables.Greeter = whiteLables.init(null);

    type TextArray = [Text];

    type Project = {
        id: Text;
        name: Text;
        owner: Principal;
        admins: [Principal];
    };

    // stable var newDB = 
    // public shared (msg) func new() {

    // }

    // stable var state : ?whiteLables.BigState = null;
    // stable var greeter: ?whiteLables.Greeter = null;

    public func sayHello() {
        greeter.sayHello();
    };


    public func store(key:Text, val: Text) {
        let valBlob = to_candid(val);
        ignore await kv.put(key, valBlob, false);
    };

    public func get2(key:Text): async ?Text {
        let valBlob = await kv.get(key);
        switch (valBlob) {
            case (?b) {
                let val: ?Text = from_candid b;
            };
            case (_) {
                null;
            };
        };
        
    };


    // public shared (msg) func init2() {
    //     switch(dbState) {
    //         case (?db) {

    //         }
    //     }
    //     let myPrincipal = msg.caller;
    //     let (ekvdb, ekvm) = EkvmModule.init(100, 40000, myPrincipal, myPrincipal, myPrincipal);

    //     dbState:= ekvm;
    //     db2:= ekvm;
    //     // db := ?EkvmModule.create(100, 40000, myPrincipal, myPrincipal, myPrincipal);
    //     gs := ?{
    //         var text = "David";
    //         var blob = to_candid("Moshe");
    //     };


    //     greeter := whiteLables.init(gs);
    //     greeter.sayHello();
    //     // let b = BTree.init<Nat32, BTree.BTree<Text, Principal>>(null);
    //     // let w = WhiteLabels(b);
    //     // switch (db) {
    //     //     case (?ekvm) {
    //     //         let whiteLabel = WhiteLabels(ekvm);
    //     //         Debug.print("whiteLable principal: " # Principal.toText(Principal.fromActor(whiteLabel)));
    //     //     };
    //     //     case (_) {
    //     //         Debug.print("Failed to initialize db");
    //     //     };
    //     // };
    // };

    // public func StoreSomething(key: Text,val: Text) {
    //     await 
    // }

    public func useState() {
        kv := EkvmModule.getDB(db);
    };

    public shared (msg) func init() {
        let myPrincipal = msg.caller;
        db := ?EkvmModule.create(100, 40000, myPrincipal, myPrincipal, myPrincipal);
        kv := EkvmModule.getDB(db);
        gs := ?{
            var text = "David";
            var blob = to_candid("Moshe");
        };


        greeter := whiteLables.init(gs);
        greeter.sayHello();
        // let b = BTree.init<Nat32, BTree.BTree<Text, Principal>>(null);
        // let w = WhiteLabels(b);
        // switch (db) {
        //     case (?ekvm) {
        //         let whiteLabel = WhiteLabels(ekvm);
        //         Debug.print("whiteLable principal: " # Principal.toText(Principal.fromActor(whiteLabel)));
        //     };
        //     case (_) {
        //         Debug.print("Failed to initialize db");
        //     };
        // };
    };


    public func createProject(project: Project) {
        switch (db) {
            case (?ekvm) {
                let projectBlob: Blob = to_candid(project);
                let principals = Array.append([project.owner], project.admins);
                let indexes: [Text] = Array.map<Principal, Text>(principals, func p = "projectsOf:"# Principal.toText(p));

                //  for (admin in project.admins.vals()) {
                //     Array.append(indexes, [["projectsOf:"# Principal.toText(project.owner)]])
                //  }
                ignore await add(ekvm, project.id,  "projects", Array.append(["allProjects"],indexes), projectBlob);
            };
            case (_) {
                Debug.print("not initialized!");
                // return false;
            };
        };
    };

    public func getProjectIdsFor(principal: ?Principal): async ?TextArray {
        switch (db) {
            case (?ekvm) {
                var key:Text = "";
                switch (principal) {
                    case (?p) {
                        key := "projectsOf:" # Principal.toText(p);
                    };
                    case (_) {
                        key := "allProjects";
                    };
                };
                await getKeys(ekvm, key);
                // let aas = await getKeys(ekvm, "projectsOf:aaaaa-aa");
                // Debug.print("aa's " # debug_show(aas));
                // all;
            };
            case (_) {
                Debug.print("not initialized!");
                null;
            };
        };
    };

    // public func getProject(id: Text): async Project {
    //     switch (db) {

    //     }
    // }

    public func createWhiteLabel(id : Text, name : Text) : async Bool {
        Debug.print("Creating white label with name: " # name # " and id: " # id);
        switch (db) {
            case (?ekvm) {
                ignore await EkvmModule._put(ekvm, "whiteLabel:" # id, Text.encodeUtf8(name), false);
                switch (await EkvmModule._get(ekvm, "whiteLabelKeys")) {
                    case (?keysBlob) {
                        let keys : ?TextArray = from_candid  keysBlob;
                        Debug.print("the keys: " # debug_show(keys) );
                        switch (keys) {
                            case (?keysArray) {
                                let newKeys = Array.append(keysArray, [id]);
                                 let keysArrayBlob: Blob = to_candid(newKeys);
                                ignore await EkvmModule._put(ekvm, "whiteLabelKeys", keysArrayBlob, false);
                                return true;
                            };
                            case (_) {
                                // Handle the case where getting the keys failed
                                Debug.print("Failed to get whiteLabelKeys");
                                let keysArray : TextArray = [id];
                                 let keysArrayBlob: Blob = to_candid(keysArray);
                                ignore await EkvmModule._put(ekvm, "whiteLabelKeys", keysArrayBlob, false);
                                return true;
                            };
                        };
                    };
                    case (_) {
                        // Handle the case where getting the keys failed
                        Debug.print("Failed to get whiteLabelKeys");
                        let keysArray : TextArray = [id];
                        let keysArrayBlob = to_candid (keysArray);
                        await EkvmModule._put(ekvm, "whiteLabelKeys", keysArrayBlob, false);
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
