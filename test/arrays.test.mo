// import { test; suite } "mo:test/async";
// import Debug "mo:base/Debug";
// import Principal "mo:base/Principal";
// import Blob "mo:base/Blob";
// import EkvmModule "../src/Ekvm";
// import Array "mo:base/Array";
// import Text "mo:base/Text";
// import Cycles "mo:base/ExperimentalCycles";
// import StableMemory "mo:base/ExperimentalStableMemory";
// import Nat64 "mo:base/Nat64";
// import Iter "mo:base/Iter";
// import Nat "mo:base/Nat";
// import Nat8 "mo:base/Nat8";
// import BTree "mo:stableheapbtreemap/BTree";
// import BucketModule "../src/BucketModule";
// import BucketActor "../src/BucketActor";
// import Utils "../src/utils";
// import Result "mo:base/Result";
// import Experimental "mo:base/Experimental"; // Import for Candid functions

// type MyObject = {
//   id: Nat;
//   name: Text;
//   isActive: Bool;
// };

// await suite("Array Utils Test Suite", func(): async () {
//   await test("test array", func(): async () {
//     let myObject: MyObject = {
//       id = 42;
//       name = "Motoko";
//       isActive = true;
//     };

//     // Serialize the object to a blob using Experimental.Candid
//     let blob: Blob = Experimental.Candid.encode(myObject);
//     Debug.print(debug_show(blob));

//     // Deserialize the blob back to an object using Experimental.Candid
//     let deserializedObject: ?MyObject = Experimental.Candid.decode<MyObject>(blob);
//     switch deserializedObject {
//       case (?obj) {
//         Debug.print("Deserialized object: " # debug_show(obj));
//       };
//       case null {
//         Debug.print("Failed to deserialize object.");
//       };
//     };
//   });
// });


import Debug "mo:base/Debug";

type MyObject = {
  id: Nat;
  name: Text;
  isActive: Bool;
};

let myObject: MyObject = {
  id = 42;
  name = "Motoko";
  isActive = true;
};

// Serialize the object to a blob using to_candid
let blob: Blob = to_candid(myObject);
Debug.print(debug_show(blob));

// Deserialize the blob back to an object using from_candid
let deserializedObject: ?MyObject = from_candid  blob;
Debug.print(debug_show(deserializedObject));
