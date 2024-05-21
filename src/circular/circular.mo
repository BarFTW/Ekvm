// import EkvmModule "../Ekvm";
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
import EMModule "managedEntity";

actor {

    // type r = Result.Result<Text, Text>;
    stable var db : ?EkvmModule.Ekvm = null;

    var kv : EkvmModule.EKVDB = EkvmModule.getDB(db);

    var cols = Collection.init(kv);
    var whiteLabels = EMModule.init(kv, "whiteLabels");
    var projects = EMModule.init(kv, "projects");


    // stable var gs : ?whiteLables.ComplexState = null;
    // var greeter: whiteLables.Greeter = whiteLables.init(null);

    type TextArray = [Text];

    class MyClass() {
        private let a = 4;
    };

    public type ManagedEntity = {
        wlId : Text;
        id : Text;
        name : Text;
        owner : Principal;
        admins : [Principal];
    };

    // public type Project =  {
    //     id: Text;
    //     name: Text;
    //     owner: Principal;
    //     admins: [Principal];
    //     homePage: Text;
    // };

    public type ProjectData = {
        homePage : Text;
        webHooks : ?[{ event : Text; url : Text }];
    };

    public type Project = {
        entity : ManagedEntity;
        additionalData : ProjectData;
    };

    public type WhiteLabel = {
        entity : ManagedEntity;
        members : [Text];
    };

    public func useState() {
        kv := EkvmModule.getDB(db);
    };

    public shared (msg) func init() {
        let myPrincipal = msg.caller;
        db := ?EkvmModule.create(100, 40000, myPrincipal, myPrincipal, myPrincipal);
        kv := EkvmModule.getDB(db);
        ignore Debug.print("after init db: "#debug_show(db));
    };

    private func createEntity(entity : ManagedEntity, typeName : Text, objBlob : Blob) : async () {
        let principals = Array.append([entity.owner], entity.admins);
        let indexes : [Text] = Array.map<Principal, Text>(principals, func p = "wlId:" # entity.wlId # "-" # typeName # "Of:" # Principal.toText(p));

        ignore await cols.add(entity.id, "wlId:" # entity.wlId# "-"#typeName, Array.append(["all-" # typeName, "wlId:" # entity.wlId # "-all-" #typeName], indexes), objBlob);

    };

    // private func getEntity(typeName: Text, id:Text): async ?Blob {
    //     let fullKey = typeName # ":" # id;
    //     let blob = await cols.get(fullKey);
    // };

    private func getEntityIdsFor(principal : ?Principal, typeName : Text, wlId : ?Text) : async ?TextArray {
        var key : Text = "";
        switch (principal, wlId) {

            case (?p, ?wlId) {
                key := "wlId:" # wlId # "-" #typeName # "Of:" # Principal.toText(p);
            };

            case (?p, _) {
                return null;
            };

            case (_,?wlId) {
                key := "wlId:" # wlId # "-all-" # typeName;
            };

            case (_, _) {
                key := "all-" # typeName;
            };

        };
        await cols.getKeys(key);
    };

    // public func createProject(project : Project) : async () {
    //     let projectBlob : Blob = to_candid (project);
    //     ignore await createEntity(project.entity, "projects", projectBlob);
    //     // let principals = Array.append([project.entity.owner], project.entity.admins);
    //     // let indexes: [Text] = Array.map<Principal, Text>(principals, func p = "projectsOf:"# Principal.toText(p));

    //     // ignore await cols.add(project.id,  "projects", Array.append(["allProjects"],indexes), projectBlob);
    // };

    public func createProject(project : Project) : async () {
        let projectBlob : Blob = to_candid (project);
        ignore await projects.createEntity(project.entity, projectBlob);
        // let principals = Array.append([project.entity.owner], project.entity.admins);
        // let indexes: [Text] = Array.map<Principal, Text>(principals, func p = "projectsOf:"# Principal.toText(p));

        // ignore await cols.add(project.id,  "projects", Array.append(["allProjects"],indexes), projectBlob);
    };

    public func getProjectIdsFor(principal : ?Principal, wlId : ?Text) : async ?TextArray {
        await projects.getEntityIdsFor(principal, wlId);
    };

    public func getProject(id : Text, wlId : Text) : async ?Project {
        let b = await cols.get("wlId:" #wlId # "-projects", id);
        Debug.print("project blob: " # debug_show (b));
        switch (b) {
            case (?blob) from_candid blob;
            case (_) null;
        };
    };

    public func createWhiteLabel(wl : WhiteLabel) : async () {
        // Debug.print("Creating white label with name: " # name # " and id: " # id);
        let wlBlob = to_candid (wl);
        ignore await createEntity(wl.entity, "whiteLabels", wlBlob);
    };

    public func getWhiteLabelIdsFor(principal : ?Principal, wlId : ?Text) : async ?TextArray {
        await getEntityIdsFor(principal, "whiteLabels", wlId);
    };

    // public getWhiteLabelIds(principal: ?Principal): async ?TextArray {
    //     getEntityIdsFor(principal, "whiteLabels");
    // };

};
