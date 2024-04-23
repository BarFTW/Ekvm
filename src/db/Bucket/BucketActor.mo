import Text "mo:base/Text";
import BucketModule "BucketModule";

shared({caller}) actor class Bucket(numOfShards: Nat) = thisBucket {

    type BucketData = BucketModule.BucketData;
    type DataLocation = BucketModule.DataLocation;

    let bucket = BucketModule.create(numOfShards);


    public func get(key: Text) : async ?Blob {
        await BucketModule.get(bucket, key);
    };

    public func put(key: Text, value: Blob) : async Bool {
        let hsaMemory = await BucketModule.put(bucket, key, value);
        // todo: return true if theres enough memory
        // if (not hasMemory) {

        // }
    };

    public func addKeyToShard(key: Text, dataPrincipal: DataLocation) : async Bool {
        BucketModule.addKeyToShard(bucket, key, dataPrincipal);
    };

    public func whereIs(key: Text) : async ?DataLocation {
        BucketModule.whereIs(bucket, key);
    };
};
