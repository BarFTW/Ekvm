import Text "mo:base/Text";
import Debug "mo:base/Debug";
import Float "mo:base/Float";
import Buffer "mo:base/Buffer";
import Types "types";

module {
    public type Greeter = {
        sayHello: () -> Text;
    };

    public class A(name:Text) {
        public func sayHello(): Text {
            "Hello "#name; 
        };
    };

    public class B(name:Text) {
        public func sayHello(): Text {
            "Gia sas " # name; 
        };
    };

    public type SimpleRevShareConfig = {
        eventName: Text;
        revShare: Float;

    };

    public class SimpleRevShareDeal(config: SimpleRevShareConfig ) {
        public func calculate(event: Types.Event, state: Types.State): async [Types.Reward] {

            let buff = Buffer.Buffer<Types.Reward>(1);

            if (event.name == config.eventName) {
                let revShare = Float.fromInt(event.amount) * config.revShare;
                let revShareInt = Float.toInt(revShare);
                buff.add({
                    amount =revShareInt;
                });
                ignore await state.inc("total-" # event.name, event.amount);
            };
            Buffer.toArray(buff);
        };
    };

};