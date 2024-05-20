import Principal "mo:base/Principal";
import Text "mo:base/Text";
import Debug "mo:base/Debug";
import Blob "mo:base/Blob";

module {
    public type ComplexState = {
        var text: Text;
        var blob: Blob;  // Example field, replace with your actual state fields
        // Add more fields as necessary
    };


    public type Greeter = {
        sayHello: () -> ();
        updateText: (Text) -> ();
        // Add more methods as necessary
    };

    // stable var greeterState: ?ComplexState = null;

    public func init(state: ?ComplexState): Greeter {
        switch(state) {
            case (?s) {
                createGreeter(s);
            };
            case (_) {
                let dummy: ComplexState = {
                    var text="";
                    var blob = to_candid("");
                };
                createGreeter(dummy);
            };
        };
        // greeterState := ?state;
        
    };

    private func createGreeter(state: ComplexState): Greeter {
        object {
            var internalState = state;

            public func sayHello() : () {
                Debug.print("Hello " # internalState.text);
            };

            public func updateText(newText: Text) : () {
                internalState.text := newText;
                // greeterState := ?internalState;
            };

            // Add more methods to interact with the state
        }
    };

    // public func getGreeter() : ?Greeter {
    //     switch greeterState {
    //         case (null) { null };
    //         case (?state) { ?createGreeter(state) };
    //     }
    // };
};
