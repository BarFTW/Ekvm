// @testmode wasi
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat16 "mo:core/Nat16";
import Nat64 "mo:core/Nat64";
import Text "mo:core/Text";
import { suite; test } "mo:test";
import Encode "../src/Encode";
import S "../src/Schema";
import Store "../src/Store";
import T "../src/Types";
import D "schemas/Demo";

let schema : S.Schema<D.Item> = D.schema(3, D.all);
let L = Store.defaultLimits;
func never() : Bool = false;

func k(pk : Text, sk : Text) : T.Key = { pk = pk.encodeUtf8(); sk = sk.encodeUtf8() };
func item(name : Text, category : Text, price : Nat64) : Blob = D.encode({ name; category; price; payload = "" });
func put(key : T.Key, value : Blob) : T.WriteOp = #put { key; value; cond = #any };
func ok(r : T.WriteResult) : [Nat64] = switch r { case (#ok v) v; case (#err _) { assert false; [] } };
func page(r : { #ok : T.IxPage; #err : T.Err }) : T.IxPage = switch r { case (#ok p) p; case (#err _) { assert false; { rows = []; more = false } } };
func sks(p : T.ScanPage) : [Text] = p.entries.map<T.Entry, Text>(func e = switch (e.key.sk.decodeUtf8()) { case (?t) t; case null "?" });
func names(rows : [T.IxRow]) : [Text] = rows.map<T.IxRow, Text>(func r = switch (r.key.sk.decodeUtf8()) { case (?t) t; case null "?" });

func fresh() : Store.State {
  let st = Store.new();
  ignore Store.syncSchema(st, schema);
  st;
};

suite(
  "store: writes",
  func() {
    test(
      "put/get/delete with monotonic versions",
      func() {
        let st = fresh();
        assert ok(Store.write<D.Item>(st, schema, [put(k("a", "1"), "x"), put(k("a", "2"), "y")], L)) == [1, 2];
        let ?e = Store.getEntry(st, k("a", "1")) else { assert false; return };
        assert e.value == "x" and e.version == 1;
        assert ok(Store.write<D.Item>(st, schema, [put(k("a", "1"), "z")], L)) == [3];
        assert ok(Store.write<D.Item>(st, schema, [#delete { key = k("a", "2"); cond = #any }], L)) == [4];
        assert Store.getEntry(st, k("a", "2")) == null;
        assert st.primary.size() == 1;
      },
    );
    test(
      "CAS conditions and all-or-nothing batches",
      func() {
        let st = fresh();
        ignore ok(Store.write<D.Item>(st, schema, [put(k("a", "1"), "x")], L));
        assert Store.write<D.Item>(st, schema, [#put { key = k("a", "1"); value = "y"; cond = #absent }], L) == #err(#conflict { key = k("a", "1"); current = ?1 });
        assert Store.write<D.Item>(st, schema, [#put { key = k("a", "9"); value = "y"; cond = #version 1 }], L) == #err(#conflict { key = k("a", "9"); current = null });
        // second op fails: first must not be applied, version counter unchanged
        let r = Store.write<D.Item>(st, schema, [put(k("b", "1"), item("n", "c", 5)), #delete { key = k("a", "1"); cond = #version 7 }], L);
        assert r == #err(#conflict { key = k("a", "1"); current = ?1 });
        assert Store.getEntry(st, k("b", "1")) == null;
        assert st.lastVersion == 1;
        let ?ix = st.indexes.get(1 : Nat16) else { assert false; return };
        assert ix.map.size() == 0;
        assert ok(Store.write<D.Item>(st, schema, [#put { key = k("a", "1"); value = "y"; cond = #version 1 }], L)) == [2];
      },
    );
    test(
      "ops in a batch see earlier ops",
      func() {
        let st = fresh();
        let r = ok(Store.write<D.Item>(st, schema, [
          #put { key = k("a", "1"); value = "x"; cond = #absent },
          #put { key = k("a", "1"); value = "y"; cond = #version 1 },
          #delete { key = k("a", "1"); cond = #version 2 },
          #put { key = k("a", "1"); value = "z"; cond = #absent },
        ], L));
        assert r == [1, 2, 3, 4];
        let ?e = Store.getEntry(st, k("a", "1")) else { assert false; return };
        assert e.value == "z" and e.version == 4;
      },
    );
    test(
      "size limits",
      func() {
        let st = fresh();
        let big = Array.repeat<Nat8>(0, L.maxValue + 1).toBlob();
        assert Store.write<D.Item>(st, schema, [put(k("a", "1"), big)], L) == #err(#tooLarge);
        let bigKey = Array.repeat<Nat8>(1, L.maxPk + 1).toBlob();
        assert Store.write<D.Item>(st, schema, [put({ pk = bigKey; sk = "" }, "x")], L) == #err(#tooLarge);
        assert Store.write<D.Item>(st, schema, Array.repeat<T.WriteOp>(put(k("a", "1"), "x"), L.maxOps + 1), L) == #err(#tooLarge);
        assert Store.get(st, Array.repeat<T.Key>(k("a", "1"), L.maxGetKeys + 1), L) == #err(#tooLarge);
        assert st.primary.size() == 0;
      },
    );
  },
);

suite(
  "store: index maintenance",
  func() {
    test(
      "insert, move on change, keep on no-change, remove on delete",
      func() {
        let st = fresh();
        ignore ok(Store.write<D.Item>(st, schema, [put(k("p", "a"), item("apple", "fruit", 3)), put(k("p", "b"), item("bean", "veg", 1))], L));
        let ?byPrice = st.indexes.get(1 : Nat16) else { assert false; return };
        let ?byName = st.indexes.get(3 : Nat16) else { assert false; return };
        assert byPrice.map.size() == 2 and byName.map.size() == 2;
        // change price only: by_price moves, by_name unchanged
        ignore ok(Store.write<D.Item>(st, schema, [put(k("p", "a"), item("apple", "fruit", 9))], L));
        assert byPrice.map.size() == 2;
        func has(m : Map.Map<T.IxPos, ()>, ixKey : Blob, key : T.Key) : Bool = m.containsKey(Store.compareIxPos, { ixKey; key });
        assert not has(byPrice.map, Encode.nat64(3), k("p", "a"));
        assert has(byPrice.map, Encode.nat64(9), k("p", "a"));
        assert has(byName.map, Encode.text("apple"), k("p", "a"));
        // non-decodable value: stored but not indexed
        ignore ok(Store.write<D.Item>(st, schema, [put(k("p", "b"), "raw")], L));
        assert byPrice.map.size() == 1 and byName.map.size() == 1;
        ignore ok(Store.write<D.Item>(st, schema, [#delete { key = k("p", "a"); cond = #any }], L));
        for ((_, ix) in st.indexes.entries()) assert ix.map.size() == 0;
      },
    );
    test(
      "new index on non-empty shard is building; dropped index removed",
      func() {
        let st = Store.new();
        ignore Store.syncSchema(st, D.schema(1, [D.byPrice]));
        ignore ok(Store.write<D.Item>(st, D.schema(1, [D.byPrice]), [put(k("p", "a"), item("a", "c", 1))], L));
        let log = Store.syncSchema(st, D.schema(2, [D.byName]));
        assert log.size() == 2;
        assert not st.indexes.containsKey(1 : Nat16);
        assert Store.ixScan(st, { index = 3; from = #unbounded; to = #unbounded; after = null; limit = 10; reverse = false; withValues = false }, L, never) == #err(#unknownIndex);
        assert Store.setIndexReady(st, 3);
        ignore page(Store.ixScan(st, { index = 3; from = #unbounded; to = #unbounded; after = null; limit = 10; reverse = false; withValues = false }, L, never));
      },
    );
    test(
      "schema validation",
      func() {
        assert S.validate(D.schema(1, [D.byPrice, D.byPrice])) != null;
        assert S.validate(S.empty) == null;
        assert S.validate(schema) == null;
      },
    );
  },
);

suite(
  "store: partition scan",
  func() {
    let st = fresh();
    // pk "a" and "a\00" and "ab" must not leak into each other
    for (s in ["1", "2", "3", "4", "5"].values()) ignore ok(Store.write<D.Item>(st, schema, [put(k("a", s), "v")], L));
    ignore ok(Store.write<D.Item>(st, schema, [put(k("ab", "0"), "v"), put({ pk = "a\00"; sk = "0" }, "v"), put(k("", "z"), "v")], L));
    func sc(from : T.Bound, to : T.Bound, limit : Nat, reverse : Bool) : T.ScanPage = Store.scan(st, "a", from, to, limit, reverse, L, never);
    test(
      "bounds",
      func() {
        assert sks(sc(#unbounded, #unbounded, 0, false)) == ["1", "2", "3", "4", "5"];
        assert sks(sc(#unbounded, #unbounded, 0, true)) == ["5", "4", "3", "2", "1"];
        assert sks(sc(#incl "2", #excl "4", 0, false)) == ["2", "3"];
        assert sks(sc(#excl "2", #incl "4", 0, false)) == ["3", "4"];
        assert sks(sc(#excl "2", #incl "4", 0, true)) == ["4", "3"];
        assert sks(sc(#incl "2", #excl "4", 0, true)) == ["3", "2"];
        assert sks(Store.scan(st, "", #unbounded, #unbounded, 0, false, L, never)) == ["z"];
        assert sks(Store.scan(st, "a\00", #unbounded, #unbounded, 0, true, L, never)) == ["0"];
      },
    );
    test(
      "pagination with next cursor",
      func() {
        let p1 = sc(#unbounded, #unbounded, 2, false);
        assert sks(p1) == ["1", "2"] and p1.next == ?"2";
        let ?n1 = p1.next else { assert false; return };
        let p2 = sc(#excl n1, #unbounded, 3, false);
        assert sks(p2) == ["3", "4", "5"] and p2.next == null;
        let r1 = sc(#unbounded, #unbounded, 3, true);
        assert sks(r1) == ["5", "4", "3"] and r1.next == ?"3";
        let ?n2 = r1.next else { assert false; return };
        assert sks(sc(#unbounded, #excl n2, 0, true)) == ["2", "1"];
      },
    );
    test(
      "byte cap and budget stop a page early",
      func() {
        let small = { L with maxPageBytes = 40 };
        let p = Store.scan(st, "a", #unbounded, #unbounded, 0, false, small, never);
        assert sks(p) == ["1", "2"] and p.next == ?"2";
        let b = Store.scan(st, "a", #unbounded, #unbounded, 0, false, L, func() = true);
        assert sks(b) == ["1"] and b.next == ?"1";
      },
    );
  },
);

suite(
  "store: ixScan",
  func() {
    let st = fresh();
    let cats = ["fruit", "veg", "fish"];
    // 60 items over 12 partitions; prices collide on purpose to exercise tie-breaks
    let items = List.empty<(T.Key, Text, Text, Nat64)>();
    for (i in Nat.range(0, 60)) {
      let key = k("p" # (i % 12).toText(), "s" # i.toText());
      let name = "n" # ((i * 7) % 60).toText();
      let cat = cats[i % 3];
      let price = ((i * 13) % 20).toNat64();
      items.add((key, name, cat, price));
      ignore ok(Store.write<D.Item>(st, schema, [put(key, item(name, cat, price))], L));
    };
    func phys(ixKey : Blob, key : T.Key) : Blob = Store.physicalIxKey({ ixKey; key });
    // reference: by_price physical order
    let ref = items.toArray().map<(T.Key, Text, Text, Nat64), Blob>(func((key, _, _, p)) = phys(Encode.nat64(p), key)).sort(Blob.compare);
    func q(from : T.Bound, to : T.Bound, after : ?T.IxPos, limit : Nat, reverse : Bool, withValues : Bool, index : Nat16) : T.IxPage = page(Store.ixScan(st, { index; from; to; after; limit; reverse; withValues }, L, never));
    func physOf(rows : [T.IxRow]) : [Blob] = rows.map<T.IxRow, Blob>(func r = phys(r.ixKey, r.key));

    test(
      "full scan is in physical order, forward and reverse",
      func() {
        let f = q(#unbounded, #unbounded, null, 0, false, false, 1);
        assert physOf(f.rows) == ref and not f.more;
        let r = q(#unbounded, #unbounded, null, 0, true, false, 1);
        assert physOf(r.rows) == ref.reverse();
        assert f.rows[0].value == null;
      },
    );
    test(
      "paging with after equals one big page (both directions)",
      func() {
        for (rev in [false, true].values()) {
          let acc = List.empty<Blob>();
          var after : ?T.IxPos = null;
          label l loop {
            let p = q(#unbounded, #unbounded, after, 7, rev, false, 1);
            for (b in physOf(p.rows).values()) acc.add(b);
            if (not p.more) break l;
            let last = p.rows[p.rows.size() - 1];
            after := ?{ ixKey = last.ixKey; key = last.key };
          };
          assert acc.toArray() == (if rev ref.reverse() else ref);
        };
      },
    );
    test(
      "value range bounds (incl/excl) on by_price",
      func() {
        let p = q(#incl(Encode.nat64(5)), #excl(Encode.nat64(8)), null, 0, false, false, 1);
        let expect = items.toArray().filter(func((_, _, _, pr) : (T.Key, Text, Text, Nat64)) : Bool = pr >= 5 and pr < 8).size();
        assert p.rows.size() == expect;
        for (r in p.rows.values()) assert Blob.compare(r.ixKey, Encode.nat64(5)) != #less and Blob.compare(r.ixKey, Encode.nat64(8)) == #less;
        let e = q(#excl(Encode.nat64(5)), #incl(Encode.nat64(8)), null, 0, false, false, 1);
        let expect2 = items.toArray().filter(func((_, _, _, pr) : (T.Key, Text, Text, Nat64)) : Bool = pr > 5 and pr <= 8).size();
        assert e.rows.size() == expect2;
      },
    );
    test(
      "tuple prefix bounds: one category, price descending, with values",
      func() {
        let c = Encode.text("veg");
        let p = q(#incl c, #incl c, null, 0, false, true, 2);
        assert p.rows.size() == 20;
        var prev : Nat64 = 1000;
        for (r in p.rows.values()) {
          let ?v = r.value else { assert false; return };
          let ?it = D.decode(v) else { assert false; return };
          assert it.category == "veg" and it.price <= prev;
          prev := it.price;
        };
        assert q(#excl c, #excl c, null, 0, false, false, 2).rows.size() == 0;
        // everything after "veg"... nothing ("fish" < "fruit" < "veg")
        assert q(#excl c, #unbounded, null, 0, false, false, 2).rows.size() == 0;
        assert q(#unbounded, #excl c, null, 0, false, false, 2).rows.size() == 40;
      },
    );
    test(
      "limits: limit, byte cap, unknown index",
      func() {
        let p = q(#unbounded, #unbounded, null, 5, false, false, 3);
        assert p.rows.size() == 5 and p.more;
        let small = { L with maxPageBytes = 200 };
        let b = page(Store.ixScan(st, { index = 1; from = #unbounded; to = #unbounded; after = null; limit = 0; reverse = false; withValues = true }, small, never));
        assert b.rows.size() >= 1 and b.rows.size() < 60 and b.more;
        assert Store.ixScan(st, { index = 9; from = #unbounded; to = #unbounded; after = null; limit = 0; reverse = false; withValues = false }, L, never) == #err(#unknownIndex);
      },
    );
    test(
      "rows carry current version",
      func() {
        let p = q(#unbounded, #unbounded, null, 0, false, false, 3);
        for (r in p.rows.values()) {
          let ?e = Store.getEntry(st, r.key) else { assert false; return };
          assert e.version == r.version;
        };
        assert names(p.rows).size() == 60;
      },
    );
  },
);

suite(
  "store: random ops vs reference model",
  func() {
    test(
      "primary and index agree with a naive model",
      func() {
        let st = fresh();
        var seed : Nat = 12345;
        func rnd(n : Nat) : Nat { seed := (seed * 1103515245 + 12345) % 2147483648; (seed / 65536) % n };
        // model: key text -> price
        let model = List.empty<(Text, Nat64)>();
        func mget(s : Text) : ?Nat64 { for ((x, p) in model.values()) if (x == s) return ?p; null };
        func mset(s : Text, p : ?Nat64) {
          let kept = model.values().filter(func((x, _) : (Text, Nat64)) : Bool = x != s).toArray();
          model.clear();
          for (e in kept.values()) model.add(e);
          switch p { case (?v) model.add((s, v)); case null {} };
        };
        for (_ in Nat.range(0, 400)) {
          let s = "k" # rnd(40).toText();
          let key = k("p" # rnd(4).toText(), s);
          let id = key.pk.decodeUtf8();
          let full = switch id { case (?t) t # "/" # s; case null s };
          if (rnd(4) == 0) {
            ignore ok(Store.write<D.Item>(st, schema, [#delete { key; cond = #any }], L));
            mset(full, null);
          } else {
            let p = rnd(10).toNat64();
            ignore ok(Store.write<D.Item>(st, schema, [put(key, item(s, "c", p))], L));
            mset(full, ?p);
          };
        };
        assert st.primary.size() == model.size();
        for ((_, ix) in st.indexes.entries()) assert ix.map.size() == model.size();
        let rows = page(Store.ixScan(st, { index = 1; from = #unbounded; to = #unbounded; after = null; limit = 0; reverse = false; withValues = false }, L, never)).rows;
        assert rows.size() == model.size();
        var i = 1;
        while (i < rows.size()) { assert Blob.compare(rows[i - 1].ixKey, rows[i].ixKey) != #greater; i += 1 };
        for (r in rows.values()) {
          let full = switch (r.key.pk.decodeUtf8(), r.key.sk.decodeUtf8()) { case (?a, ?b) a # "/" # b; case _ "" };
          assert ?r.ixKey == (switch (mget(full)) { case (?p) ?Encode.nat64(p); case null null });
        };
      },
    );
  },
);

suite(
  "store: dedupe and helpers",
  func() {
    test(
      "dedupe remembers results until TTL",
      func() {
        let st = fresh();
        let lim = { L with dedupeTtlNs = 100 };
        Store.dedupeRecord(st, "r1", 1000, #ok([1]));
        assert Store.dedupeLookup(st, "r1", 1050, lim) == ?#ok([1]);
        assert Store.dedupeLookup(st, "r1", 1101, lim) == null;
        assert Store.dedupeLookup(st, "", 1000, lim) == null;
        Store.dedupePurge(st, 1101, lim, 10);
        assert st.dedupe.size() == 0;
        // size cap
        let capped = { L with maxDedupe = 2 };
        for (i in Nat.range(0, 5)) Store.dedupeRecord(st, Encode.nat8(i.toNat8()), 2000, #ok([]));
        Store.dedupePurge(st, 2000, capped, 10);
        assert st.dedupe.size() == 2;
      },
    );
    test(
      "prefixSucc and succ",
      func() {
        assert Store.prefixSucc("\01\02") == ?"\01\03";
        assert Store.prefixSucc("\01\ff\ff") == ?"\02";
        assert Store.prefixSucc("\ff") == null;
        assert Store.prefixSucc("") == null;
        assert Store.succ("\01") == "\01\00";
      },
    );
  },
);
