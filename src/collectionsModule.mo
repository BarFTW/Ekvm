import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Debug "mo:base/Debug";
import Text "mo:base/Text";
import EkvmModule "Ekvm";

module {

    type TextArray = [Text];

    public func add(ekvm : EkvmModule.Ekvm, key : Text, dataPath : Text, indexes : [Text], blob : Blob) : async Bool {
        Debug.print("Adding item with key: " # key # " to collection: " # dataPath);
        let fullKey = dataPath # ":" # key;
        ignore await EkvmModule._put(ekvm, fullKey, blob, false);
        for (indexPath in indexes.vals()) {
            Debug.print("adding indexes: " # debug_show(indexPath));
            let keysKey = indexPath;
            switch (await EkvmModule._get(ekvm, keysKey)) {
                case (?keysBlob) {
                    let keys : ?TextArray = from_candid keysBlob;
                    switch (keys) {
                        case (?keysArray) {
                            let newKeys = Array.append<Text>(keysArray, [key]);
                            let keysArrayBlob : Blob = to_candid (newKeys);
                            ignore await EkvmModule._put(ekvm, keysKey, keysArrayBlob, false);
                        };
                        case null {
                            Debug.print("Failed to decode keys, initializing new keys array");
                            let keysArray : TextArray = [key];
                            let keysArrayBlob : Blob = to_candid (keysArray);
                            ignore await EkvmModule._put(ekvm, keysKey, keysArrayBlob, false);
                        };
                    };
                };
                case null {
                    Debug.print("No existing keys found, initializing new keys array");
                    let keysArray : TextArray = [key];
                    let keysArrayBlob : Blob = to_candid (keysArray);
                    ignore await EkvmModule._put(ekvm, keysKey, keysArrayBlob, false);
                };
            };
        };
        return true;
    };

    public func get(ekvm : EkvmModule.Ekvm, keyPath : Text, key : Text) : async ?Blob {
        let fullKey = keyPath;
        await EkvmModule._get(ekvm, fullKey);
    };

    public func getKeys(ekvm : EkvmModule.Ekvm, keyPath : Text) : async ?TextArray {
        let keysKey = keyPath;
        switch (await EkvmModule._get(ekvm, keysKey)) {
            case (?keysBlob) {
                from_candid keysBlob;
            };
            case null {
                null;
            };
        };
    };
};
