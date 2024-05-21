import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Debug "mo:base/Debug";
import Text "mo:base/Text";
import EkvmModule "Ekvm";

module {

    type TextArray = [Text];

    public type Collection = {
        add : (key : Text, dataPath : Text, indexes : [Text], value : Blob) -> async Bool;
        get : (keyPath : Text, key : Text) -> async ?Blob;
        getNew : (keyPath : Text) -> async ?Blob;
        getKeys : (keyPath : Text) -> async ?[Text];
    };

    public func init(kv : EkvmModule.EKVDB) : Collection {
        object {
            public func add(_:Text, dataPath : Text, indexes : [Text], blob : Blob) : async Bool {
                Debug.print("Adding item to collection: " # dataPath);
                let fullKey = dataPath;// # ":" # key;
                ignore await kv.put(fullKey, blob, false);
                for (indexPath in indexes.vals()) {
                    Debug.print("adding indexes: " # debug_show (indexPath));
                    let keysKey = indexPath;
                    switch (await kv.get(keysKey)) {
                        case (?keysBlob) {
                            let keys : ?TextArray = from_candid keysBlob;
                            switch (keys) {
                                case (?keysArray) {
                                    let newKeys = Array.append<Text>(keysArray, [dataPath]);
                                    let keysArrayBlob : Blob = to_candid (newKeys);
                                    ignore await kv.put(keysKey, keysArrayBlob, false);
                                };
                                case null {
                                    Debug.print("Failed to decode keys, initializing new keys array");
                                    let keysArray : TextArray = [dataPath];
                                    let keysArrayBlob : Blob = to_candid (keysArray);
                                    ignore await kv.put(keysKey, keysArrayBlob, false);
                                };
                            };
                        };
                        case null {
                            Debug.print("No existing keys found, initializing new keys array");
                            let keysArray : [Text] = [dataPath];
                            let keysArrayBlob : Blob = to_candid (keysArray);
                            ignore await kv.put(keysKey, keysArrayBlob, false);
                        };
                    };
                };
                return true;
            };

            public func get(keyPath : Text, key : Text) : async ?Blob {
                let fullKey = keyPath # ":" # key;
                await kv.get(fullKey);
            };

            public func getNew(keyPath : Text) : async ?Blob {
                let fullKey = keyPath ;// # ":" # key;
                await kv.get(fullKey);
            };

            public func getKeys(keyPath : Text) : async ?TextArray {
                let keysKey = keyPath;
                switch (await kv.get(keysKey)) {
                    case (?keysBlob) {
                        from_candid keysBlob;
                    };
                    case null {
                        null;
                    };
                };
            };
        };
    };
};
