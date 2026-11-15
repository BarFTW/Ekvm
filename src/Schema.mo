/// Schema: secondary indexes declared in Motoko and compiled into the shard
/// wasm (DESIGN.md §3, D4). A shard build picks its schema via the moc package
/// `ekvm-schema` (see scripts/build.sh); that package's `Schema.mo` must export
/// `public let schema : Schema.Schema<V>` for some value type `V`.
///
/// `decode` turns the stored value into `V` once per written entry; every
/// index's `extract` then reads the decoded value. Use `Schema.raw` (V = Blob)
/// to extract directly from the bytes.
import Nat16 "mo:core/Nat16";
import Text "mo:core/Text";

module {
  /// `extract` returns an order-preserving encoded index key built with
  /// `Encode` (e.g. `Encode.tuple([Encode.text(c), Encode.desc(Encode.nat64(p))])`),
  /// or null when the entry is not indexed. It must be deterministic. A trap
  /// in `decode`/`extract` aborts the whole write message.
  public type IndexDef<V> = {
    id : Nat16;
    name : Text;
    extract : (pk : Blob, sk : Blob, value : V) -> ?Blob;
  };

  public type Schema<V> = {
    /// Bump when indexes are added, removed or their extractors change.
    version : Nat;
    /// null: the value is stored but not indexed.
    decode : (value : Blob) -> ?V;
    indexes : [IndexDef<V>];
  };

  public func raw(value : Blob) : ?Blob = ?value;

  public let empty : Schema<Blob> = { version = 0; decode = raw; indexes = [] };

  /// Duplicate ids or names make a schema invalid.
  public func validate<V>(s : Schema<V>) : ?Text {
    let n = s.indexes.size();
    var i = 0;
    while (i < n) {
      var j = i + 1;
      while (j < n) {
        if (s.indexes[i].id == s.indexes[j].id) return ?("duplicate index id " # s.indexes[i].id.toText());
        if (s.indexes[i].name == s.indexes[j].name) return ?("duplicate index name " # s.indexes[i].name);
        j += 1;
      };
      i += 1;
    };
    null;
  };
};
