// import EkvmModule "../Ekvm";
import EkvmModule "../Ekvm";
import Principal "mo:base/Principal";
import Text "mo:base/Text";
import Debug "mo:base/Debug";

// import Cycles "mo:base/ExperimentalCycles";
// import StableMemory "mo:base/ExperimentalStableMemory";

// import Nat64 "mo:base/Nat64";
// import Iter "mo:base/Iter";
// import Nat "mo:base/Nat";
// import Result "mo:base/Result";
import Blob "mo:base/Blob";
// import BTree "mo:stableheapbtreemap/BTree";
// import BucketModule "../BucketModule";
// import BucketActor "../BucketActor";
// import Utils "../utils";
import Array "mo:base/Array";
// import { JSON; Candid; CBOR } "mo:serde";
import Collection "../collectionsModule";
import EMModule "managedEntity";

actor {

    stable var db : ?EkvmModule.Ekvm = null;

    var kv : EkvmModule.EKVDB = EkvmModule.getDB(db);

    // var cols = Collection.init(kv);
    var whiteLabels = EMModule.EntityManager(kv, "whiteLabels");
    var projects = EMModule.EntityManager(kv, "projects");


    public type ProjectData = {
        homePage : Text;
        webHooks : ?[{ event : Text; url : Text }];
    };

    public type Project = {
        entity : EMModule.ManagedEntity;
        additionalData : ProjectData;
    };

    public type WhiteLabel = {
        entity : EMModule.ManagedEntity;
        members : [Text];
    };

    public func useState() {
        kv := EkvmModule.getDB(db);
    };

    public shared (msg) func init() {
        let myPrincipal = msg.caller;
        db := ?EkvmModule.create(100, 40000, myPrincipal, myPrincipal, myPrincipal);
        kv := EkvmModule.getDB(db);
        Debug.print("after init db: "#debug_show(db));
    };


    public func createProject(project : Project) : async () {
        let projectBlob : Blob = to_candid (project);
        await projects.createEntity(project.entity, projectBlob);
    };

    public func getProjectIdsFor(principal : ?Principal, wlId : ?Text) : async ?[Text] {
        await projects.getEntityIdsFor(principal, wlId);
    };

    public func getProject(id : Text, wlId : Text) : async ?Project {
        let b = await projects.get(id, wlId);
        switch (b) {
            case (?blob) from_candid blob;
            case (_) null;
        };
    };

    public func createWhiteLabel(wl : WhiteLabel) : async () {
        let wlBlob = to_candid (wl);
        await whiteLabels.createEntity(wl.entity, wlBlob);
    };

    public func getWhiteLabelIdsFor(principal : ?Principal, wlId : ?Text) : async ?[Text] {
        await whiteLabels.getEntityIdsFor(principal, wlId);
    };

    public func getWhiteLabel(id: Text): async ?WhiteLabel {
        let b = await whiteLabels.get(id, id);
        switch (b) {
            case (?blob) from_candid blob;
            case (_) null;
        };
    };
};
