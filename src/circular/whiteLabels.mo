import Principal "mo:base/Principal";
import Debug "mo:base/Debug";
import EkvmModule "../Ekvm";
import { add; get; getKeys} "../collectionsModule";

// actor class WhiteLabels( db: EkvmModule.Ekvm) {

//     public func create(id: Text, name: Text) {
//         let nameBlob: Blob = to_candid(name);
//         ignore await add(db, id,  "whiteLables", ["allWhiteLables"], nameBlob);
//     };

//     public func getWhiteLableIds() : async Text {
//         await getKeys(db, "allWhiteLables");
//     };
// }

// actor {};