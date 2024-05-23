import Text "mo:base/Text";
import Debug "mo:base/Debug";
import Float "mo:base/Float";
import Buffer "mo:base/Buffer";
import Blob "mo:base/Blob";
import Types "types";
import Simple "simple";
module {
    public func getCalculator(actorPrincipal: Principal, dealType: Text, thisActorPrincipal: Principal, configBlob: Blob ): ?Types.DealCalculator {
        Debug.print("in getCalculator");
        if (dealType=="simpleRevShare" ) {
            let configO: ?Simple.SimpleRevShareConfig = from_candid(configBlob);
            switch (configO) {
                case (?config) {
                        return ?Simple.SimpleRevShareDeal(config);
                };
                case (_) {
                    Debug.trap("not a valid config");
                };
            };
        } else {
            Debug.print("unknown dealType "# dealType);
            return null;
        };
    };
};