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
    var whiteLabels = EMModule.EntityManager(kv, "whiteLabels",[],[
        [(#Principal, 0)], //WL by principal
        [] // all WLs
    ]);
    var projects = EMModule.EntityManager(kv, "projects",["wl","id"],[
        [(#Principal, 0)], //projects by principal
        [(#Principal, 0), (#IdPart, 0)], //project by principal and WL,
        [(#IdPart, 0)],
        [] // all projects
    ]);
    var campaigns = EMModule.EntityManager(kv, "campaigns",["wl","proj", "id"],[
        [(#Principal,0),(#IdPart,0), (#IdPart,1)], //all campaigns by principal, wl and project
        [(#Principal,0),(#IdPart,1)], // all campaigns by principal and project
        [(#IdPart,0)] //all campaigns by wl
    ]);

    public type Campaign = {
        entity :  EMModule.ManagedEntity;
        dateFrom: Text;
        dateTo: Text;
        active: Bool;
    };

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
        await projects.createEntityNew(project.entity, projectBlob);
    };

    public func createCampaign(campaign: Campaign) : async () {
        let campaignBlob : Blob = to_candid (campaign);
        await campaigns.createEntityNew(campaign.entity, campaignBlob);
    };

    public func getCampaign(ids:[Text]): async ?Campaign {
        let b = await campaigns.getNew(ids);
         switch (b) {
            case (?blob) from_candid blob;
            case (_) null;
        };
    };

    public func getCampaignByKey(key:Text): async ?Campaign {
        let b = await campaigns.get(key);
         switch (b) {
            case (?blob) from_candid blob;
            case (_) null;
        };
    };

    public func getCampaignIdsByWL(wlId: Text) : async ?[Text] {
        await campaigns.getEntityKeysByIndex(null, [wlId], [(#IdPart,0)]);
    };

    public func getCampaignIdsByWLandProj(wlId: Text, projectId : Text) : async ?[Text] {
        await campaigns.getEntityKeysByIndex(null, [wlId, projectId], [(#IdPart,0), (#IdPart,1)]);
    };

    public func getProjectKeysFor(principal : ?Principal, wlId : ?Text) : async ?[Text] {
        switch(principal, wlId) {
            case (?p, ?w) {
                await projects.getEntityKeysByIndex(principal, [w], [(#Principal,0),(#IdPart,0)]);
            };
            case (?p, _) {
                await projects.getEntityKeysByIndex(principal, [], [(#Principal,0)]);
            };
            case (_, ?w) {
                await projects.getEntityKeysByIndex(null, [w], [(#IdPart,0)]);
            };
            case (_,_) {
                await projects.getEntityKeysByIndex(null, [], []);
            };

        };
        
    };

    public func getProject(id : Text, wlId : Text) : async ?Project {
        let b = await projects._get(id, wlId);
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
        let b = await whiteLabels._get(id, id);
        switch (b) {
            case (?blob) from_candid blob;
            case (_) null;
        };
    };
};
