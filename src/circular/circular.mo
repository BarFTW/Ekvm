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
import Buffer "mo:base/Buffer";
// import BTree "mo:stableheapbtreemap/BTree";
// import BucketModule "../BucketModule";
// import BucketActor "../BucketActor";
// import Utils "../utils";
import Array "mo:base/Array";
// import { JSON; Candid; CBOR } "mo:serde";
import Collection "../collectionsModule";
import EMModule "managedEntity";
import Simple "deals/simple";
import DealTypes "deals/types";
import DealFactory "deals/factory";
import { JSON;  } "mo:serde";
// import { DealCalculator; Reward} "deals/types";

actor Circular{

    stable var db : ?EkvmModule.Ekvm = null;

    var kv : EkvmModule.EKVDB = EkvmModule.getDB(db);

    // var cols = Collection.init(kv);
    var whiteLabels = EMModule.EntityManager(kv, "whiteLabels",["id"],[
        [(#Principal, 0)], //WL by principal
        [] // all WLs
    ]);
    var projects = EMModule.EntityManager(kv, "projects",["wl","id"],[
        [(#Principal, 0)], //projects by principal
        [(#Principal, 0), (#IdPart, 0)], //project by principal and WL,
        [(#IdPart, 0)], // projects by WL
        [] // all projects
    ]);
    var campaigns = EMModule.EntityManager(kv, "campaigns",["wl","proj", "id"],[
        [(#Principal,0),(#IdPart,0), (#IdPart,1)], //all campaigns by principal, wl and project
        [(#Principal,0),(#IdPart,1)], // all campaigns by principal and project
        [(#IdPart,0)] //all campaigns by wl
    ]);

    var offers = EMModule.EntityManager(kv, "offers",["wl","proj", "cmp", "id"],[
        [(#Principal,0),(#IdPart,0), (#IdPart,1)], //all campaigns by principal, wl and project
        [(#Principal,0),(#IdPart,1)], // all campaigns by principal and project
        [(#IdPart,0)] //all campaigns by wl
    ]);

    public type Campaign = {
        entity :  EMModule.ManagedEntity;
        name : Text;
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
        name : Text;
        additionalData : ProjectData;
    };

    public type WhiteLabel = {
        name : Text;
        entity : EMModule.ManagedEntity;
        members : [Text];
    };

    public type Reward = {
        amount: Nat;
    };

    public type Event = {
        name: Text;
        amount: Nat;
        count: Nat;
    };

    // public type DealCalculator = {
    //     calculate: (Event, State: Blob) -> [Reward];
    // };

    public type Offer = {
        entity : EMModule.ManagedEntity;
        calculatorActor: Principal;
        dealType: Text;
        config: Blob;
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

    public query func getCampaignIdsFromKey(key: Text): async [Text] {
        campaigns.getIdsFromKey(key);
    };

    public func createProject(project : Project) : async () {
        let projectBlob : Blob = to_candid (project);
        await projects.createEntity(project.entity, projectBlob);
    };

    public func createCampaign(campaign: Campaign) : async () {
        let campaignBlob : Blob = to_candid (campaign);
        await campaigns.createEntity(campaign.entity, campaignBlob);
    };

    public func getCampaign(ids:[Text]): async ?Campaign {
        let b = await campaigns.getByIds(ids);
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

    public func getProject(key : Text) : async ?Project {
        let b = await projects.get(key);
        switch (b) {
            case (?blob) from_candid blob;
            case (_) null;
        };
    };

    public func createWhiteLabel(wl : WhiteLabel) : async () {
        let wlBlob = to_candid (wl);
        await whiteLabels.createEntity(wl.entity, wlBlob);
    };

    public func getWhiteLabelIdsFor(principal : ?Principal) : async ?[Text] {
        switch (principal) {
            case (?p) {
                await whiteLabels.getEntityKeysByIndex(principal, [],[(#Principal,0)]);
            };
            case (_) {
                await whiteLabels.getEntityKeysByIndex(null, [],[]);
            };
        };
    };

    public func getWhiteLabel(key: Text): async ?WhiteLabel {
        let b = await whiteLabels.get(key);
        switch (b) {
            case (?blob) from_candid blob;
            case (_) null;
        };
    };



    public func CreateOffer(offer: Offer, configJson: Text): async () {
        let #ok(blob) = JSON.fromText(configJson, null); 
        Debug.print("blob: "# debug_show(blob));

        let config: ?Simple.SimpleRevShareConfig = from_candid(blob);
        switch (config) {
            case (?c) {
                let calc = Simple.SimpleRevShareDeal(c);
                Debug.print("after create calc, offer:  "#debug_show(offer) );
                let newOffer = { offer with config = blob };
                Debug.print("new Offer " # debug_show(newOffer));
                let b = to_candid(newOffer);
                ignore await offers.createEntity(offer.entity, b);
                Debug.print("After creating offer, b: "#debug_show(b));

            };
            case (_) {
                Debug.trap("invalid config");
            };
        };
        
        Debug.print("config "# debug_show(config));
        let b = to_candid(offer);
    };

     public func fetchOffer(key:Text) : async ?(Offer, Text, Text) {
        let bOpt = await offers.get(key);
        switch (bOpt) {
            case (?b) {
                let offerOpt: ?Offer = from_candid b;
                switch (offerOpt) {
                    case (?offer) {
                        let #ok(text) = JSON.toText(offer.config, ["eventName","revShare","flat"], null);
                        ?(offer,text,key);
                    };
                    case (_) null;
                };
            };
            case (_) null;
        };
    };

    public func getAllOffers(wl:Text): async [(Offer, Text, Text)] {

        let keysOpt = await offers.getEntityKeysByIndex(null, [wl],[(#IdPart,0)]);
        switch (keysOpt) {
            case (?keys) {
                let size = Array.size(keys);
                let buff = Buffer.Buffer<(Offer, Text, Text)>(size);
                for (key in keys.vals()) {
                    let oOpt = await fetchOffer(key);
                    switch (oOpt) {
                        case (?o) buff.add(o);
                        case (_) ();
                    };
                };
                Buffer.toArray(buff);
            };
            case (_) {
                [];
            };
        };

    };

    public func onEvent(event: DealTypes.Event, dealKey: Text): async [DealTypes.Reward] {
        let tupOpt = await fetchOffer(dealKey);
        switch (tupOpt) {
            case (?(offer, config, _)) {
                Debug.print("offer "#debug_show(offer));
                let myPrincipal = Principal.fromActor(Circular);
                let calcOpt = DealFactory.getCalculator(myPrincipal, "simpleRevShare", myPrincipal, offer.config);
                Debug.print("after getCalculator: ");

                switch (calcOpt) {
                    case (?calc) {
                        Debug.print("after creating calc");
                        let state  = DealTypes.DummyState();
                        await calc.calculate(event, state);
                    };
                    case (_) {
                        Debug.trap("oh no, no deal calculator");
                        [];
                    };
                }
            };
            case (_) {
                Debug.print("no offer found");
                []
            };
        }
    };

    public query func greet(greek: Bool): async Text  {
        var g: Simple.Greeter = Simple.A("");
        if (greek) {
            g:= Simple.B("Yanis");
        } else {
            g:=Simple.A("Johnny");
        };
        g.sayHello();
    };

};
