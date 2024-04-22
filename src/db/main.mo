import EkvmModule "Ekvm/EkvmModule";
import Principal "mo:base/Principal";
import Text "mo:base/Text";
import Debug "mo:base/Debug";

actor class TestDBUser() = this {

    var db : ?EkvmModule.Ekvm = null;

    public func init() {
        let myPrincipal = Principal.fromActor(this);
        db := ?EkvmModule.create(1000, 0, myPrincipal, myPrincipal, myPrincipal);
    };

    public func test() : async?Text {
        switch(db) {
            case(?db) { 
                Debug.print "1";
                ignore EkvmModule.put(db, "foo", Text.encodeUtf8("bar"));
                Debug.print "2";
                // ignore EkvmModule.put(db, "hello", Text.encodeUtf8("world"));
                // ignore EkvmModule.put(db, "bla", Text.encodeUtf8("bla"));

                switch(await EkvmModule.get(db, "foo")) {
                    case (?a) {
                        Debug.print(debug_show (a));
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
            case(_) { null };
        };
    }
};