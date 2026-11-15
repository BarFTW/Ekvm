// Single-shard client (M1): typed wrappers over the shard Candid API, opaque
// pagination cursors, and the physical key layout shared with src/Store.mo.
// Multi-shard routing and the global ordered query arrive in M2.
import { IDL } from "@icp-sdk/core/candid";
import { bytes, compareBytes, concat } from "./encode.ts";
import { Bound as BoundIdl, IxPos as IxPosIdl } from "./idl.ts";

export type Route = { epoch: bigint; slotBits: number };
export type Key = { pk: Uint8Array; sk: Uint8Array };
export type Entry = { key: Key; value: Uint8Array; version: bigint };
export type Cond = { any: null } | { absent: null } | { version: bigint };
export type Bound = { incl: Uint8Array } | { excl: Uint8Array } | { unbounded: null };
export type WriteOp =
  | { put: { key: Key; value: Uint8Array; cond: Cond } }
  | { delete: { key: Key; cond: Cond } };
export type Err =
  | { wrongShard: { epoch: bigint; slotBits: number } }
  | { conflict: { key: Key; current: [] | [bigint] } }
  | { unauthorized: null } | { tooLarge: null } | { migrating: null } | { unknownIndex: null };
export type IxPos = { ixKey: Uint8Array; key: Key };
export type IxRow = { ixKey: Uint8Array; key: Key; version: bigint; value: [] | [Uint8Array] };
type Res<T> = { ok: T } | { err: Err };

/** Structural type of a shard actor created from `shardIdl`. */
export interface ShardActor {
  write(req: { route: Route; requestId: Uint8Array; ops: WriteOp[] }): Promise<Res<bigint[]>>;
  get(req: { route: Route; keys: Key[] }): Promise<Res<([] | [Entry])[]>>;
  getCertainly(req: { route: Route; keys: Key[] }): Promise<Res<([] | [Entry])[]>>;
  scan(req: { route: Route; pk: Uint8Array; from: Bound; to: Bound; limit: bigint; reverse: boolean }): Promise<Res<{ entries: Entry[]; next: [] | [Uint8Array] }>>;
  ixScan(req: {
    route: Route; index: number; from: Bound; to: Bound; after: [] | [IxPos];
    limit: bigint; reverse: boolean; withValues: boolean;
  }): Promise<Res<{ rows: IxRow[]; more: boolean }>>;
}

export class EkvmError extends Error {
  readonly err: Err;
  constructor(err: Err) {
    super(`ekvm: ${Object.keys(err)[0]}`);
    this.err = err;
  }
}

const unwrap = <T>(r: Res<T>): T => {
  if ("err" in r) throw new EkvmError(r.err);
  return r.ok;
};

export const unbounded: Bound = { unbounded: null };
export const incl = (b: Uint8Array): Bound => ({ incl: b });
export const excl = (b: Uint8Array): Bound => ({ excl: b });

/** Primary map key: bytes(pk) ‖ sk (same as Store.primaryKey). */
export const primaryKey = (k: Key): Uint8Array => concat(bytes(k.pk), k.sk);
/** Byte form of an index position: ixKey ‖ bytes(pk) ‖ sk (same as Store.physicalIxKey). */
export const physicalIxKey = (ixKey: Uint8Array, k: Key): Uint8Array => concat(ixKey, bytes(k.pk), k.sk);
export const rowPosition = (r: IxRow): IxPos => ({ ixKey: r.ixKey, key: r.key });
export const compareKeys = (a: Key, b: Key): number => compareBytes(a.pk, b.pk) || compareBytes(a.sk, b.sk);
/** Shard order of index rows: (ixKey, pk, sk) component-wise. */
export const compareRows = (a: IxPos, b: IxPos): number => compareBytes(a.ixKey, b.ixKey) || compareKeys(a.key, b.key);

// ---------------------------------------------------------------- cursors

const ScanCursorIdl = IDL.Record({
  v: IDL.Nat8, pk: IDL.Vec(IDL.Nat8), from: BoundIdl, to: BoundIdl, reverse: IDL.Bool, next: IDL.Vec(IDL.Nat8),
});
/** DESIGN.md §5.3 cursor; `after` is the last returned row's position. */
const IxCursorIdl = IDL.Record({
  v: IDL.Nat8, index: IDL.Nat16, schemaVersion: IDL.Nat, from: BoundIdl, to: BoundIdl, reverse: IDL.Bool,
  after: IxPosIdl, epoch: IDL.Nat64, slotBits: IDL.Nat8,
});
export type ScanCursor = { v: number; pk: Uint8Array; from: Bound; to: Bound; reverse: boolean; next: Uint8Array };
export type IxCursor = {
  v: number; index: number; schemaVersion: bigint; from: Bound; to: Bound; reverse: boolean;
  after: IxPos; epoch: bigint; slotBits: number;
};

const b64 = (b: Uint8Array) => Buffer.from(b).toString("base64url");
const unb64 = (s: string) => new Uint8Array(Buffer.from(s, "base64url"));
const fixBound = (b: any): Bound => ("incl" in b ? { incl: new Uint8Array(b.incl) } : "excl" in b ? { excl: new Uint8Array(b.excl) } : unbounded);

export const encodeScanCursor = (c: ScanCursor): string => b64(new Uint8Array(IDL.encode([ScanCursorIdl], [c])));
export const decodeScanCursor = (s: string): ScanCursor => {
  const [c] = IDL.decode([ScanCursorIdl], unb64(s)) as any[];
  if (c.v !== 1) throw new Error("unsupported cursor version");
  return { v: c.v, pk: new Uint8Array(c.pk), from: fixBound(c.from), to: fixBound(c.to), reverse: c.reverse, next: new Uint8Array(c.next) };
};
export const encodeIxCursor = (c: IxCursor): string => b64(new Uint8Array(IDL.encode([IxCursorIdl], [c])));
export const decodeIxCursor = (s: string): IxCursor => {
  const [c] = IDL.decode([IxCursorIdl], unb64(s)) as any[];
  if (c.v !== 1) throw new Error("unsupported cursor version");
  const a = c.after;
  return { ...c, from: fixBound(c.from), to: fixBound(c.to), after: { ixKey: new Uint8Array(a.ixKey), key: { pk: new Uint8Array(a.key.pk), sk: new Uint8Array(a.key.sk) } } };
};

export const newRequestId = (): Uint8Array => crypto.getRandomValues(new Uint8Array(16));

export type ScanOpts = { from?: Bound; to?: Bound; limit?: number; reverse?: boolean; cursor?: string | null };
export type IxScanOpts = ScanOpts & { withValues?: boolean };

export class ShardClient {
  readonly actor: ShardActor;
  readonly route: () => Route;
  readonly schemaVersion: bigint;

  constructor(actor: ShardActor, route: () => Route, opts: { schemaVersion?: bigint } = {}) {
    this.actor = actor;
    this.route = route;
    this.schemaVersion = opts.schemaVersion ?? 0n;
  }

  /**
   * Atomic batch on one shard. Returns one version per op. Transport failures
   * are retried with the same requestId, so the shard's dedupe table makes the
   * retry safe (DESIGN.md §10).
   */
  async batch(ops: WriteOp[], opts: { requestId?: Uint8Array; retries?: number } = {}): Promise<bigint[]> {
    const requestId = opts.requestId ?? newRequestId();
    for (let attempt = 0; ; attempt++) {
      try {
        return unwrap(await this.actor.write({ route: this.route(), requestId, ops }));
      } catch (e) {
        if (e instanceof EkvmError || attempt >= (opts.retries ?? 0)) throw e;
      }
    }
  }

  async put(key: Key, value: Uint8Array, cond: Cond = { any: null }): Promise<bigint> {
    return (await this.batch([{ put: { key, value, cond } }]))[0]!;
  }

  async delete(key: Key, cond: Cond = { any: null }): Promise<bigint> {
    return (await this.batch([{ delete: { key, cond } }]))[0]!;
  }

  async get(keys: Key[], opts: { certain?: boolean } = {}): Promise<(Entry | null)[]> {
    const req = { route: this.route(), keys };
    const r = unwrap(await (opts.certain ? this.actor.getCertainly(req) : this.actor.get(req)));
    return r.map((o) => (o.length ? o[0] : null));
  }

  async getOne(key: Key, opts: { certain?: boolean } = {}): Promise<Entry | null> {
    return (await this.get([key], opts))[0]!;
  }

  /** One page of a partition scan; pass the returned cursor to continue. */
  async scan(pk: Uint8Array, opts: ScanOpts = {}): Promise<{ entries: Entry[]; cursor: string | null }> {
    let { from = unbounded, to = unbounded, reverse = false } = opts;
    if (opts.cursor) {
      const c = decodeScanCursor(opts.cursor);
      if (compareBytes(c.pk, pk) !== 0) throw new Error("cursor belongs to another partition");
      ({ from, to, reverse } = c);
      if (reverse) to = excl(c.next); else from = excl(c.next);
    }
    const page = unwrap(await this.actor.scan({ route: this.route(), pk, from, to, limit: BigInt(opts.limit ?? 0), reverse }));
    const next = page.next.length ? page.next[0] : null;
    const orig = opts.cursor ? decodeScanCursor(opts.cursor) : { from: opts.from ?? unbounded, to: opts.to ?? unbounded };
    const cursor = next ? encodeScanCursor({ v: 1, pk, from: orig.from, to: orig.to, reverse, next }) : null;
    return { entries: page.entries, cursor };
  }

  async *scanAll(pk: Uint8Array, opts: Omit<ScanOpts, "cursor"> = {}): AsyncGenerator<Entry> {
    let cursor: string | null = null;
    do {
      const p: { entries: Entry[]; cursor: string | null } = await this.scan(pk, { ...opts, cursor });
      yield* p.entries;
      cursor = p.cursor;
    } while (cursor);
  }

  /** One page of this shard's slice of a local index (single-shard; global merge is M2). */
  async ixScan(index: number, opts: IxScanOpts = {}): Promise<{ rows: IxRow[]; cursor: string | null }> {
    let { from = unbounded, to = unbounded, reverse = false } = opts;
    let after: [] | [IxPos] = [];
    if (opts.cursor) {
      const c = decodeIxCursor(opts.cursor);
      if (c.index !== index) throw new Error("cursor belongs to another index");
      ({ from, to, reverse } = c);
      after = [c.after];
    }
    const route = this.route();
    const page = unwrap(await this.actor.ixScan({
      route, index, from, to, after, limit: BigInt(opts.limit ?? 0), reverse, withValues: opts.withValues ?? false,
    }));
    const last = page.rows[page.rows.length - 1];
    const cursor = page.more && last
      ? encodeIxCursor({ v: 1, index, schemaVersion: this.schemaVersion, from, to, reverse, after: rowPosition(last), epoch: route.epoch, slotBits: route.slotBits })
      : null;
    return { rows: page.rows, cursor };
  }

  async *ixScanAll(index: number, opts: Omit<IxScanOpts, "cursor"> = {}): AsyncGenerator<IxRow> {
    let cursor: string | null = null;
    do {
      const p: { rows: IxRow[]; cursor: string | null } = await this.ixScan(index, { ...opts, cursor });
      yield* p.rows;
      cursor = p.cursor;
    } while (cursor);
  }
}
