import Text "mo:base/Text";
import BucketModule "BucketModule";

shared({caller}) actor class Bucket(numOfShards: Nat) = thisBucket {

    type BucketData = BucketModule.BucketData;
    type DataLocation = BucketModule.DataLocation;

    let bucket = BucketModule.create(numOfShards, null);


    public func get(key: Text) : async ?Blob {
        await BucketModule.get(bucket, key);
    };

    public func put(key: Text, value: Blob) : async Bool {
        await BucketModule.put(bucket, key, value);
    };

    public func addKeyToShard(key: Text, dataPrincipal: DataLocation) : async Bool {
        await BucketModule.addKeyToShard(bucket, key, dataPrincipal);
    };

    public func whereIs(key: Text) : async ?DataLocation {
        BucketModule.whereIs(bucket, key);
    };
};
