#!/usr/bin/env python3
"""Independent reference implementation of Ekvm's key encodings and key hash.

Generates the shared test vectors consumed by the Motoko and TypeScript test
suites:
  test/vectors/vectors.json   (read by the TS tests)
  test/Vectors.mo             (generated Motoko module, read by the Motoko tests)

Python is deliberately a *third* implementation: neither Motoko nor TS is the
source of truth; both must agree with this file. Spec: docs/ENCODING.md.
Run: python3 tools/gen_vectors.py [--check]
"""
import hashlib, json, math, struct, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent

# ---------- reference encoders (docs/ENCODING.md) ----------
def nat_fixed(x, n):
    assert 0 <= x < 1 << (8 * n)
    return x.to_bytes(n, "big")

def int_fixed(x, n):
    assert -(1 << (8 * n - 1)) <= x < 1 << (8 * n - 1)
    return ((x + (1 << (8 * n))) % (1 << (8 * n)) ^ (1 << (8 * n - 1))).to_bytes(n, "big")

def nat_var(x):
    assert x >= 0
    b = x.to_bytes((x.bit_length() + 7) // 8, "big") if x else b""
    assert len(b) <= 255
    return bytes([len(b)]) + b

def int_var(x):
    if x == 0:
        return b"\x80"
    m = abs(x)
    b = m.to_bytes((m.bit_length() + 7) // 8, "big")
    assert len(b) <= 127
    if x > 0:
        return bytes([0x80 + len(b)]) + b
    return bytes([0x80 - len(b)]) + bytes(255 - c for c in b)

def float64(f):
    assert not math.isnan(f), "NaN is not encodable"
    if f == 0.0:
        f = 0.0  # normalise -0.0 to +0.0
    (u,) = struct.unpack(">Q", struct.pack(">d", f))
    u = (u ^ 0xFFFFFFFFFFFFFFFF) if (u >> 63) else (u | (1 << 63))
    return u.to_bytes(8, "big")

def bool_(b):
    return b"\x01" if b else b"\x00"

def bytes_(b):
    return b.replace(b"\x00", b"\x00\xff") + b"\x00\x00"

def text(t):
    return bytes_(t.encode("utf-8"))

def desc(b):
    return bytes(255 - c for c in b)

# ---------- key hash and slots ----------
def key_hash(pk):
    return int.from_bytes(hashlib.sha256(pk).digest()[:4], "big")

def slot_of(h, bits):
    assert 1 <= bits <= 32
    return h >> (32 - bits)

# ---------- shard map helpers ----------
def even_ranges(num_shards, bits):
    total = 1 << bits
    return [(i * total // num_shards, i) for i in range(num_shards)]

def double_ranges(ranges):
    return [(first * 2, s) for first, s in ranges]

def lookup(ranges, slot):
    best = None
    for first, s in ranges:
        if first <= slot:
            best = s
    return best

# ---------- vectors ----------
FIXED = {
    "nat8": (1, [0, 1, 127, 128, 255]),
    "nat16": (2, [0, 1, 255, 256, 65535]),
    "nat32": (4, [0, 1, 65536, 4294967295]),
    "nat64": (8, [0, 1, 4294967296, 18446744073709551615]),
}
IFIXED = {
    "int8": (1, [-128, -1, 0, 1, 127]),
    "int16": (2, [-32768, -256, -1, 0, 1, 32767]),
    "int32": (4, [-2147483648, -65536, -1, 0, 1, 2147483647]),
    "int64": (8, [-9223372036854775808, -4294967296, -1, 0, 1, 9223372036854775807]),
}
NATS = [0, 1, 255, 256, 65535, 65536, 2**64 - 1, 2**64, 2**100]
INTS = [-(2**100), -(2**64), -65536, -256, -255, -1, 0, 1, 255, 256, 2**64, 2**100]
FLOATS = [-math.inf, -1e308, -1.5, -1.0, -5e-324, 0.0, 5e-324, 1.0, 1.5, 3.141592653589793, 1e308, math.inf]
TEXTS = ["", "\u0000", "\u0000\u0000", "a", "a\u0000", "a\u0000b", "ab", "b", "z", "\u00e9", "\u05d0", "\U0001F600"]
BLOBS = [b"", b"\x00", b"\x00\x00", b"\x00\x01", b"\x01", b"\xfe", b"\xff", b"\xff\x00", b"\xff\xff"]
PKS = [b"", b"a", b"abc", b"campaign:42", bytes(range(32)), b"\xff" * 7]
SLOT_BITS = [1, 8, 16, 17, 31, 32]

def hexs(b):
    return b.hex()

def float_repr(f):
    if math.isinf(f):
        return "inf" if f > 0 else "-inf"
    return repr(f)

def build():
    v = {"spec": "docs/ENCODING.md", "fixedNat": [], "fixedInt": [], "nat": [], "int": [],
         "float": [], "bool": [], "text": [], "blob": [], "desc": [], "tuple": [], "hash": [], "shardMap": []}
    for t, (n, xs) in FIXED.items():
        for x in xs:
            v["fixedNat"].append({"type": t, "value": str(x), "hex": hexs(nat_fixed(x, n))})
    for t, (n, xs) in IFIXED.items():
        for x in xs:
            v["fixedInt"].append({"type": t, "value": str(x), "hex": hexs(int_fixed(x, n))})
    v["nat"] = [{"value": str(x), "hex": hexs(nat_var(x))} for x in NATS]
    v["int"] = [{"value": str(x), "hex": hexs(int_var(x))} for x in INTS]
    v["float"] = [{"value": float_repr(f), "hex": hexs(float64(f))} for f in FLOATS]
    v["float"].append({"value": "-0.0", "hex": hexs(float64(-0.0))})
    v["bool"] = [{"value": b, "hex": hexs(bool_(b))} for b in (False, True)]
    v["text"] = [{"value": t, "hex": hexs(text(t))} for t in TEXTS]
    v["blob"] = [{"value": hexs(b), "hex": hexs(bytes_(b))} for b in BLOBS]
    v["desc"] = [
        {"of": "text", "value": t, "hex": hexs(desc(text(t)))} for t in ["", "a", "ab", "b"]
    ] + [{"of": "int64", "value": str(x), "hex": hexs(desc(int_fixed(x, 8)))} for x in [-1, 0, 1]]
    v["tuple"] = [
        {"parts": [["text", "a"], ["nat64", "1"]], "hex": hexs(text("a") + nat_fixed(1, 8))},
        {"parts": [["text", "a\u0000"], ["nat64", "0"]], "hex": hexs(text("a\u0000") + nat_fixed(0, 8))},
        {"parts": [["desc_float", "1.5"], ["blob", "00ff"]], "hex": hexs(desc(float64(1.5)) + bytes_(b"\x00\xff"))},
    ]
    for pk in PKS:
        h = key_hash(pk)
        v["hash"].append({"pk": hexs(pk), "hash": h, "slots": {str(b): slot_of(h, b) for b in SLOT_BITS}})
    for shards, bits in [(1, 16), (3, 16), (4, 8), (64, 16), (5, 1 + 4)]:
        r = even_ranges(shards, bits)
        probes = sorted({0, (1 << bits) - 1, (1 << bits) // 3, (1 << bits) // 2})
        d = double_ranges(r)
        v["shardMap"].append({
            "shards": shards, "slotBits": bits, "ranges": r,
            "lookups": [[p, lookup(r, p)] for p in probes],
            "doubled": d,
            "doubledLookups": [[q, lookup(d, q)] for p in probes for q in (2 * p, 2 * p + 1)],
        })
    return v

# ---------- Motoko emitter ----------
def mo_text(s):
    out = []
    for ch in s:
        c = ord(ch)
        if ch == '"' or ch == "\\":
            out.append("\\" + ch)
        elif 32 <= c < 127:
            out.append(ch)
        else:
            out.append("\\u{%x}" % c)
    return '"' + "".join(out) + '"'

def mo_float(s):
    if s == "inf":
        return "(1.0 / 0.0)"
    if s == "-inf":
        return "(-1.0 / 0.0)"
    f = float(s)
    r = repr(f)
    if "e" in r and "." not in r.split("e")[0]:
        m, e = r.split("e")
        r = m + ".0e" + e
    r = r.replace("e+", "e")
    if "e" not in r and "." not in r:
        r += ".0"
    return "(" + r + ")"

def emit_mo(v):
    L = ["// GENERATED by tools/gen_vectors.py. Do not edit.", "module {"]
    L.append("  public let fixedNat : [(Text, Nat, Text)] = [")
    L += [f'    ("{e["type"]}", {e["value"]}, "{e["hex"]}"),' for e in v["fixedNat"]] + ["  ];"]
    L.append("  public let fixedInt : [(Text, Int, Text)] = [")
    L += [f'    ("{e["type"]}", {e["value"]}, "{e["hex"]}"),' for e in v["fixedInt"]] + ["  ];"]
    L.append("  public let nat : [(Nat, Text)] = [")
    L += [f'    ({e["value"]}, "{e["hex"]}"),' for e in v["nat"]] + ["  ];"]
    L.append("  public let int : [(Int, Text)] = [")
    L += [f'    ({e["value"]}, "{e["hex"]}"),' for e in v["int"]] + ["  ];"]
    L.append("  // A function, not a let: 1.0 / 0.0 is not a static expression.")
    L.append("  public func float() : [(Float, Text)] = [")
    L += [f'    ({mo_float(e["value"])}, "{e["hex"]}"),' for e in v["float"]] + ["  ];"]
    L.append("  public let bool : [(Bool, Text)] = [")
    L += [f'    ({str(e["value"]).lower()}, "{e["hex"]}"),' for e in v["bool"]] + ["  ];"]
    L.append("  public let text : [(Text, Text)] = [")
    L += [f'    ({mo_text(e["value"])}, "{e["hex"]}"),' for e in v["text"]] + ["  ];"]
    L.append("  public let blob : [(Text, Text)] = [")
    L += [f'    ("{e["value"]}", "{e["hex"]}"),' for e in v["blob"]] + ["  ];"]
    L.append("  public let descText : [(Text, Text)] = [")
    L += [f'    ({mo_text(e["value"])}, "{e["hex"]}"),' for e in v["desc"] if e["of"] == "text"] + ["  ];"]
    L.append("  public let descInt64 : [(Int, Text)] = [")
    L += [f'    ({e["value"]}, "{e["hex"]}"),' for e in v["desc"] if e["of"] == "int64"] + ["  ];"]
    L.append("  public let hash : [(Text, Nat32, [(Nat8, Nat32)])] = [")
    for e in v["hash"]:
        slots = ", ".join(f"({b}, {s})" for b, s in e["slots"].items())
        L.append(f'    ("{e["pk"]}", {e["hash"]}, [{slots}]),')
    L.append("  ];")
    L.append("  public type MapVector = { shards : Nat; slotBits : Nat8; ranges : [(Nat32, Nat16)]; lookups : [(Nat32, Nat16)]; doubled : [(Nat32, Nat16)]; doubledLookups : [(Nat32, Nat16)] };")
    L.append("  public let shardMap : [MapVector] = [")
    fmt = lambda xs: "[" + ", ".join(f"({a}, {b})" for a, b in xs) + "]"
    for e in v["shardMap"]:
        L.append(f'    {{ shards = {e["shards"]}; slotBits = {e["slotBits"]}; ranges = {fmt(e["ranges"])}; lookups = {fmt(e["lookups"])}; doubled = {fmt(e["doubled"])}; doubledLookups = {fmt(e["doubledLookups"])} }},')
    L.append("  ];")
    L.append("}")
    return "\n".join(L) + "\n"

def selfcheck(v):
    # ordering properties of the reference itself
    def ascending(enc, xs):
        es = [enc(x) for x in xs]
        assert es == sorted(es), enc
        assert len(set(es)) == len(es)
    for t, (n, xs) in FIXED.items(): ascending(lambda x: nat_fixed(x, n), xs)
    for t, (n, xs) in IFIXED.items(): ascending(lambda x: int_fixed(x, n), xs)
    ascending(nat_var, NATS); ascending(int_var, INTS); ascending(float64, FLOATS)
    ascending(text, sorted(TEXTS, key=lambda t: t.encode())); ascending(bytes_, sorted(BLOBS))
    es = [desc(text(t)) for t in ["", "a", "ab", "b"]]; assert es == sorted(es, reverse=True)

def main():
    v = build(); selfcheck(v)
    js = json.dumps(v, indent=1, ensure_ascii=False) + "\n"
    mo = emit_mo(v)
    targets = {ROOT / "test/vectors/vectors.json": js, ROOT / "test/Vectors.mo": mo}
    if "--check" in sys.argv:
        stale = [str(p) for p, c in targets.items() if not p.exists() or p.read_text() != c]
        if stale:
            print("stale:", *stale); sys.exit(1)
        print("vectors up to date"); return
    for p, c in targets.items():
        p.write_text(c)
    print("wrote", *targets)

if __name__ == "__main__":
    main()
