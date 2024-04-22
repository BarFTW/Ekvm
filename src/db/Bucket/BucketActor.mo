import Text "mo:base/Text";
import BucketModule "BucketModule";

shared({caller}) actor class Bucket(numOfShards: Nat) = thisBucket {

    type BucketData = BucketModule.BucketData;
    type DataLocation = BucketModule.DataLocation;

    let bucket = BucketModule.create(numOfShards);


    public func get(key: Text) : async ?Blob {
        bucket.data.get(key);
    };

    public func put(key: Text, value: Blob) : async Bool {
        bucket.data.put(key, value);
        true;
        // todo: return true if theres enough memory
    };

    // public func getShard(id) : 

    public func addKeyToShard(key: Text, dataPrincipal: DataLocation) : async Bool {
        BucketModule.addKeyToShard(bucket, key, dataPrincipal);
    };

    public func whereIs(key: Text) : async ?DataLocation {
        BucketModule.whereIs(bucket, key);
    };
};
