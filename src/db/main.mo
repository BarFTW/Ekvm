import EkvmModule "Ekvm/EkvmModule";
import Principal "mo:base/Principal";
import Text "mo:base/Text";
import Debug "mo:base/Debug";
import StableMemory "mo:base/ExperimentalStableMemory";
import Nat64 "mo:base/Nat64";
import Iter "mo:base/Iter";
import Nat "mo:base/Nat";


actor class TestDBUser() = this {

    stable var db : ?EkvmModule.Ekvm = null;

    public func init() {
        Debug.print "----init----";
        let memoryUsage = StableMemory.stableVarQuery();
        let beforeSize = (await memoryUsage()).size;

        let myPrincipal = Principal.fromActor(this);
        db := ?EkvmModule.create(100, 4000, myPrincipal, myPrincipal, myPrincipal);
        let afterSize = (await memoryUsage()).size;

        Debug.print("init_afterSize - " # debug_show (afterSize));
        Debug.print("init_beforeSize - " # debug_show (beforeSize));
        Debug.print("init_diff - " # debug_show (afterSize - beforeSize));
    };

    public func test() : async ?Text {
        let memoryUsage = StableMemory.stableVarQuery();
        switch(db) {
            case(?db) { 
                Debug.print "----test----";
        let beforeSize = (await memoryUsage()).size;
        var afterSize: Nat64 = 0;

                for (i in Iter.range(0, 1000000)) {
                    if (i % 1000 == 0){
                        afterSize := (await memoryUsage()).size;
                        Debug.print("i - " # Nat.toText(i) # "; afterSize - " # Nat64.toText(afterSize));
                    };
                    ignore await EkvmModule.put(db, "foo" # Nat.toText(i), Text.encodeUtf8("bar" # Nat.toText(i)));
                };
        afterSize := (await memoryUsage()).size;

        Debug.print("test_afterSize - " # debug_show (afterSize));
        Debug.print("test_beforeSize - " # debug_show (beforeSize));
        Debug.print("test_diff - " # debug_show (afterSize - beforeSize));

                switch(await EkvmModule.get(db, "foo")) {
                    case (?a) {
                        return Text.decodeUtf8(a);
                        // switch(await EkvmModule.get(db, "hello")) {
                        //     case(?b) { 
                        //         switch(await EkvmModule.get(db, "bla")) {
                        //             case(?c) { 
                        //                 return Text.decodeUtf8(a) # "_" # Text.decodeUtf8(b) # "_" # Text.decodeUtf8(c);
                        //              };
                        //             case(null) { null };
                        //         };
                        //      };
                        //     case(null) { null };
                        // };
                    };
                    case (_) { null };
                }
             };
            case(_) {
                Debug.print "no db";
                null
            };
        };
    }
};