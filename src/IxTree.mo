/// IxTree: a B+tree specialised for index positions (DESIGN.md D11, M3
/// locality experiment).
///
/// Every node keeps, next to its keys, two parallel arrays of small scalars:
/// the first 14 bytes of an order-preserving byte stream for each key, packed
/// 7 bytes per `Nat` (< 2^56, so stored unboxed). Binary search compares those
/// scalars first and only dereferences the full key on a 14-byte tie, so a
/// lookup touches mostly the node's own arrays instead of one heap object per
/// comparison. Leaves are doubly linked for range iteration.
///
/// Deletion removes the entry from its leaf without rebalancing: underfull or
/// empty leaves stay in place and are refilled by later inserts in their key
/// range (memory follows the high-water mark of the index).
import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Order "mo:core/Order";
import VarArray "mo:core/VarArray";
import T "Types";

module {
  /// Default order: max keys per leaf and max children per internal node.
  public let defaultOrder = 64;

  public type Leaf = {
    var n : Nat;
    p1 : [var Nat];
    p2 : [var Nat];
    ks : [var T.IxPos];
    var next : ?Leaf;
    var prev : ?Leaf;
  };

  public type Internal = {
    var n : Nat; // number of children; separators = n - 1
    p1 : [var Nat];
    p2 : [var Nat];
    seps : [var T.IxPos];
    children : [var Node];
  };

  public type Node = { #leaf : Leaf; #internal : Internal };

  public type Tree = { order : Nat; var root : Node; var size : Nat };

  let dummy : T.IxPos = { ixKey = ""; key = { pk = ""; sk = "" } };

  func newLeaf(B : Nat) : Leaf = {
    var n = 0;
    p1 = VarArray.repeat<Nat>(0, B);
    p2 = VarArray.repeat<Nat>(0, B);
    ks = VarArray.repeat<T.IxPos>(dummy, B);
    var next = null;
    var prev = null;
  };

  func newInternal(B : Nat, first : Node) : Internal = {
    var n = 1;
    p1 = VarArray.repeat<Nat>(0, B - 1);
    p2 = VarArray.repeat<Nat>(0, B - 1);
    seps = VarArray.repeat<T.IxPos>(dummy, B - 1);
    children = VarArray.repeat<Node>(first, B);
  };

  public func empty() : Tree = emptyWithOrder(defaultOrder);

  /// `order` >= 4; small orders exercise splits in tests.
  public func emptyWithOrder(order : Nat) : Tree = { order; var root = #leaf(newLeaf(order)); var size = 0 };

  public func size(t : Tree) : Nat = t.size;

  public func compare(a : T.IxPos, b : T.IxPos) : Order.Order {
    switch (Blob.compare(a.ixKey, b.ixKey)) {
      case (#equal) {
        switch (Blob.compare(a.key.pk, b.key.pk)) { case (#equal) Blob.compare(a.key.sk, b.key.sk); case o o };
      };
      case o o;
    };
  };

  /// Prefix of the stream esc(ixKey) 00 00 esc(pk) 00 00 sk, where esc maps
  /// byte 00 to 00 FF. The stream orders exactly like `compare`, and a
  /// zero-padded prefix of it is monotone, so equal prefixes only mean "tie".
  public func prefix(p : T.IxPos) : (Nat, Nat) {
    var a = 0;
    var b = 0;
    var i = 0;
    func push(x : Nat8) {
      if (i < 7) a := a * 256 + x.toNat() else if (i < 14) b := b * 256 + x.toNat();
      i += 1;
    };
    func esc(bl : Blob) {
      label l for (x in bl.values()) {
        if (i >= 14) break l;
        push(x);
        if (x == 0) push(0xff);
      };
      push(0);
      push(0);
    };
    esc(p.ixKey);
    if (i < 14) esc(p.key.pk);
    if (i < 14) label l for (x in p.key.sk.values()) { if (i >= 14) break l; push(x) };
    while (i < 7) { a := a * 256; i += 1 };
    while (i < 14) { b := b * 256; i += 1 };
    (a, b);
  };

  /// Search key with its prefix precomputed.
  type Q = { k : T.IxPos; a : Nat; b : Nat };

  func q(k : T.IxPos) : Q { let (a, b) = prefix(k); { k; a; b } };

  func cmpAt(x : Q, p1 : [var Nat], p2 : [var Nat], ks : [var T.IxPos], i : Nat) : Order.Order {
    let a = p1[i];
    if (x.a < a) return #less;
    if (x.a > a) return #greater;
    let b = p2[i];
    if (x.b < b) return #less;
    if (x.b > b) return #greater;
    compare(x.k, ks[i]);
  };

  /// First index in [0, n) whose key is >= x (or > x when `strict`).
  func bound(x : Q, p1 : [var Nat], p2 : [var Nat], ks : [var T.IxPos], n : Nat, strict : Bool) : Nat {
    var lo = 0;
    var hi = n;
    while (lo < hi) {
      let mid = (lo + hi) / 2;
      let c = cmpAt(x, p1, p2, ks, mid);
      let goRight = if strict c != #less else c == #greater;
      if (goRight) lo := mid + 1 else hi := mid;
    };
    lo;
  };

  /// Child to descend into: number of separators <= x.
  func childOf(x : Q, nd : Internal) : Nat = bound(x, nd.p1, nd.p2, nd.seps, nd.n - 1, true);

  func leafFor(t : Tree, x : Q) : Leaf {
    var nd = t.root;
    loop {
      switch nd {
        case (#leaf l) return l;
        case (#internal i) nd := i.children[childOf(x, i)];
      };
    };
  };

  // ------------------------------------------------------------ insert

  type Split = ?{ sep : T.IxPos; a : Nat; b : Nat; right : Node };

  func insertLeaf(l : Leaf, x : Q) : (Bool, Split) {
    let B = l.ks.size();
    let i = bound(x, l.p1, l.p2, l.ks, l.n, false);
    if (i < l.n and cmpAt(x, l.p1, l.p2, l.ks, i) == #equal) return (false, null);
    if (l.n < B) {
      var j = l.n;
      while (j > i) { l.p1[j] := l.p1[j - 1]; l.p2[j] := l.p2[j - 1]; l.ks[j] := l.ks[j - 1]; j -= 1 };
      l.p1[i] := x.a;
      l.p2[i] := x.b;
      l.ks[i] := x.k;
      l.n += 1;
      return (true, null);
    };
    // Split: B + 1 keys, left keeps h, right gets the rest.
    let r = newLeaf(B);
    let h = (B + 1) / 2;
    var src = 0; // index over the virtual (B + 1)-key sequence
    func get(s : Nat) : (Nat, Nat, T.IxPos) {
      if (s < i) (l.p1[s], l.p2[s], l.ks[s]) else if (s == i) (x.a, x.b, x.k) else (l.p1[s - 1], l.p2[s - 1], l.ks[s - 1]);
    };
    // Fill the right leaf first (reads only original slots >= h - 1).
    src := h;
    var j = 0;
    while (src < B + 1) {
      let (a, b, k) = get(src);
      r.p1[j] := a;
      r.p2[j] := b;
      r.ks[j] := k;
      j += 1;
      src += 1;
    };
    r.n := j;
    // Then the left leaf in place (only shifts right when i < h).
    if (i < h) {
      var s = Nat.sub(h, 1);
      while (s > i) { l.p1[s] := l.p1[s - 1]; l.p2[s] := l.p2[s - 1]; l.ks[s] := l.ks[s - 1]; s -= 1 };
      l.p1[i] := x.a;
      l.p2[i] := x.b;
      l.ks[i] := x.k;
    };
    var s = h;
    while (s < B) { l.ks[s] := dummy; s += 1 };
    l.n := h;
    r.next := l.next;
    switch (l.next) { case (?nx) nx.prev := ?r; case null {} };
    l.next := ?r;
    r.prev := ?l;
    (true, ?{ sep = r.ks[0]; a = r.p1[0]; b = r.p2[0]; right = #leaf r });
  };

  func insertNode(nd : Node, x : Q) : (Bool, Split) {
    switch nd {
      case (#leaf l) insertLeaf(l, x);
      case (#internal i) {
        let c = childOf(x, i);
        let (added, split) = insertNode(i.children[c], x);
        switch split {
          case null (added, null);
          case (?s) (added, insertChild(i, c, s.sep, s.a, s.b, s.right));
        };
      };
    };
  };

  /// Insert separator + right child after child c.
  func insertChild(nd : Internal, c : Nat, sep : T.IxPos, a : Nat, b : Nat, right : Node) : Split {
    let B = nd.children.size();
    if (nd.n < B) {
      var j = Nat.sub(nd.n, 1); // separators shift from c
      while (j > c) { nd.p1[j] := nd.p1[j - 1]; nd.p2[j] := nd.p2[j - 1]; nd.seps[j] := nd.seps[j - 1]; j -= 1 };
      nd.p1[c] := a;
      nd.p2[c] := b;
      nd.seps[c] := sep;
      var k = nd.n;
      while (k > c + 1) { nd.children[k] := nd.children[k - 1]; k -= 1 };
      nd.children[c + 1] := right;
      nd.n += 1;
      return null;
    };
    // Split a full internal node: B + 1 children, B separators (virtual).
    let ns = B; // virtual separator count
    func sepAt(s : Nat) : (Nat, Nat, T.IxPos) {
      if (s < c) (nd.p1[s], nd.p2[s], nd.seps[s]) else if (s == c) (a, b, sep) else (nd.p1[s - 1], nd.p2[s - 1], nd.seps[s - 1]);
    };
    func childAt(s : Nat) : Node {
      if (s <= c) nd.children[s] else if (s == c + 1) right else nd.children[s - 1];
    };
    let mid = ns / 2; // separator promoted
    let (ma, mb, mk) = sepAt(mid);
    let r = newInternal(B, childAt(mid + 1));
    var s = mid + 1;
    var j = 0;
    while (s < ns) {
      let (pa, pb, pk) = sepAt(s);
      r.p1[j] := pa;
      r.p2[j] := pb;
      r.seps[j] := pk;
      r.children[j + 1] := childAt(s + 1);
      j += 1;
      s += 1;
    };
    r.n := j + 1;
    // Rebuild the left part in place (positions < mid, children <= mid).
    if (c < mid) {
      var t = Nat.sub(mid, 1);
      while (t > c) { nd.p1[t] := nd.p1[t - 1]; nd.p2[t] := nd.p2[t - 1]; nd.seps[t] := nd.seps[t - 1]; t -= 1 };
      nd.p1[c] := a;
      nd.p2[c] := b;
      nd.seps[c] := sep;
      var u = mid;
      while (u > c + 1) { nd.children[u] := nd.children[u - 1]; u -= 1 };
      nd.children[c + 1] := right;
    };
    var t = mid;
    while (t + 1 < B) { nd.seps[t] := dummy; t += 1 };
    nd.n := mid + 1;
    ?{ sep = mk; a = ma; b = mb; right = #internal r };
  };

  /// Adds `k`; returns false if it was already present.
  public func add(t : Tree, k : T.IxPos) : Bool {
    let (added, split) = insertNode(t.root, q(k));
    switch split {
      case null {};
      case (?s) {
        let r = newInternal(t.order, t.root);
        r.p1[0] := s.a;
        r.p2[0] := s.b;
        r.seps[0] := s.sep;
        r.children[1] := s.right;
        r.n := 2;
        t.root := #internal r;
      };
    };
    if (added) t.size += 1;
    added;
  };

  /// Removes `k`; returns false if it was absent.
  public func remove(t : Tree, k : T.IxPos) : Bool {
    let x = q(k);
    let l = leafFor(t, x);
    let i = bound(x, l.p1, l.p2, l.ks, l.n, false);
    if (i >= l.n or cmpAt(x, l.p1, l.p2, l.ks, i) != #equal) return false;
    var j = i;
    while (j + 1 < l.n) { l.p1[j] := l.p1[j + 1]; l.p2[j] := l.p2[j + 1]; l.ks[j] := l.ks[j + 1]; j += 1 };
    l.n -= 1;
    l.ks[l.n] := dummy;
    t.size -= 1;
    true;
  };

  public func contains(t : Tree, k : T.IxPos) : Bool {
    let x = q(k);
    let l = leafFor(t, x);
    let i = bound(x, l.p1, l.p2, l.ks, l.n, false);
    i < l.n and cmpAt(x, l.p1, l.p2, l.ks, i) == #equal;
  };

  // ------------------------------------------------------------ iteration

  func firstLeaf(t : Tree) : Leaf {
    var nd = t.root;
    loop { switch nd { case (#leaf l) return l; case (#internal i) nd := i.children[0] } };
  };

  func lastLeaf(t : Tree) : Leaf {
    var nd = t.root;
    loop { switch nd { case (#leaf l) return l; case (#internal i) nd := i.children[i.n - 1] } };
  };

  /// Ascending over keys >= lo (all keys when lo = null).
  public func entriesFrom(t : Tree, lo : ?T.IxPos) : { next : () -> ?T.IxPos } {
    var leaf : ?Leaf = null;
    var i = 0;
    switch lo {
      case null { leaf := ?firstLeaf(t) };
      case (?k) {
        let x = q(k);
        let l = leafFor(t, x);
        leaf := ?l;
        i := bound(x, l.p1, l.p2, l.ks, l.n, false);
      };
    };
    {
      next = func() : ?T.IxPos {
        loop {
          switch leaf {
            case null return null;
            case (?l) {
              if (i < l.n) { let k = l.ks[i]; i += 1; return ?k };
              leaf := l.next;
              i := 0;
            };
          };
        };
      };
    };
  };

  /// Descending over keys <= hi (all keys when hi = null).
  public func reverseFrom(t : Tree, hi : ?T.IxPos) : { next : () -> ?T.IxPos } {
    var leaf : ?Leaf = null;
    var i = 0; // next key to return is at i - 1
    switch hi {
      case null { let l = lastLeaf(t); leaf := ?l; i := l.n };
      case (?k) {
        let x = q(k);
        let l = leafFor(t, x);
        leaf := ?l;
        i := bound(x, l.p1, l.p2, l.ks, l.n, true);
      };
    };
    {
      next = func() : ?T.IxPos {
        loop {
          switch leaf {
            case null return null;
            case (?l) {
              if (i > 0) { i -= 1; return ?l.ks[i] };
              leaf := l.prev;
              switch leaf { case (?p) i := p.n; case null {} };
            };
          };
        };
      };
    };
  };
};
