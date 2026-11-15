/// Demo/test value format and index extractors. Values are Candid-encoded
/// `Item` records, decoded once per write; a value that does not decode is
/// stored but not indexed.
import Blob "mo:core/Blob";
import Encode "../../src/Encode";
import S "../../src/Schema";

module {
  public type Item = { name : Text; category : Text; price : Nat64; payload : Blob };

  /// `from_candid` traps on malformed Candid (it returns null only on a type
  /// mismatch), so non-Candid values are screened by the magic header first.
  /// A trap inside `extract` aborts the whole write message (nothing applied).
  public func decode(value : Blob) : ?Item {
    if (not isCandid(value)) return null;
    from_candid (value);
  };

  func isCandid(v : Blob) : Bool {
    let it = v.values();
    for (c in ([0x44, 0x49, 0x44, 0x4c] : [Nat8]).values()) {
      switch (it.next()) { case (?d) { if (d != c) return false }; case null return false };
    };
    true;
  };
  public func encode(i : Item) : Blob = to_candid (i);

  /// 1: by price ascending.
  public let byPrice : S.IndexDef<Item> = {
    id = 1;
    name = "by_price";
    extract = func(_ : Blob, _ : Blob, i : Item) : ?Blob = ?Encode.nat64(i.price);
  };

  /// 2: by (category, price descending).
  public let byCategoryPrice : S.IndexDef<Item> = {
    id = 2;
    name = "by_category_price";
    extract = func(_ : Blob, _ : Blob, i : Item) : ?Blob = ?Encode.tuple([Encode.text(i.category), Encode.desc(Encode.nat64(i.price))]);
  };

  /// 3: by name.
  public let byName : S.IndexDef<Item> = {
    id = 3;
    name = "by_name";
    extract = func(_ : Blob, _ : Blob, i : Item) : ?Blob = ?Encode.text(i.name);
  };

  public let all : [S.IndexDef<Item>] = [byPrice, byCategoryPrice, byName];

  public func schema(version : Nat, indexes : [S.IndexDef<Item>]) : S.Schema<Item> = { version; decode; indexes };
};
