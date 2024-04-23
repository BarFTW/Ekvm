import EkvmModule "Ekvm/EkvmModule";
import Principal "mo:base/Principal";
import Text "mo:base/Text";
import Debug "mo:base/Debug";

actor class TestDBUser() = this {

    type definite_canister_settings = {
        controllers : [Principal];
        compute_allocation : Nat;
        memory_allocation : Nat;
        freezing_threshold : Nat;
        reserved_cycles_limit : Nat;
    };


    type canister_status_args = {
        canister_id : Principal;
    };

    type canister_status_result = {
        status : { #running; #stopping; #stopped };
        settings : definite_canister_settings;
        module_hash : ?Blob;
        memory_size : Nat;
        cycles : Nat;
        reserved_cycles : Nat;
        idle_cycles_burned_per_day : Nat;
    };


    var db : ?EkvmModule.Ekvm = null;

    public func init() {
                // let IC = actor("aaaaa-aa") : actor { 
                //     canister_status : (canister_status_args) -> async canister_status_result;
                // };
                // let mem = await IC.canister_status({ canister_id = Principal.fromActor(this) });
                // Debug.print(
                //     "memory_size_1: " # debug_show (mem.memory_size)
                //     # "\nmemory_allocation_1" # debug_show (mem.settings.memory_allocation)
                //     # "\ncompute_allocation_1" #debug_show (mem.settings.compute_allocation)
                // );

        Debug.print "----init----";
        let myPrincipal = Principal.fromActor(this);
        db := ?EkvmModule.create(100, 0, myPrincipal, myPrincipal, myPrincipal);
    };

    public func test() : async ?Text {
        switch(db) {
            case(?db) { 
                Debug.print "----test----";


                let IC = actor("aaaaa-aa") : actor { 
                        canister_status : (canister_status_args) -> async canister_status_result;
                };
                var mem = await IC.canister_status({ canister_id = Principal.fromActor(this) });
                Debug.print(
                    "memory_size_2: " # debug_show (mem.memory_size)
                    # "\nmemory_allocation_2: " # debug_show (mem.settings.memory_allocation)
                    # "\ncompute_allocation_2: " #debug_show (mem.settings.compute_allocation)
                );


                ignore await EkvmModule.put(db, "foo", Text.encodeUtf8("bar"));
                Debug.print "2";
                // ignore EkvmModule.put(db, "hello", Text.encodeUtf8("world"));
                // ignore EkvmModule.put(db, "bla", Text.encodeUtf8("bla"));

                mem := await IC.canister_status({ canister_id = Principal.fromActor(this) });
                Debug.print(
                    "memory_size_3: " # debug_show (mem.memory_size)
                    # "\nmemory_allocation_3: " # debug_show (mem.settings.memory_allocation)
                    # "\ncompute_allocation_3: " #debug_show (mem.settings.compute_allocation)
                );


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