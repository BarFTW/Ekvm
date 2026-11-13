// Demo value codec mirroring test/schemas/Demo.mo (Candid record `Item`).
import { IDL } from "@icp-sdk/core/candid";

export const ItemIdl = IDL.Record({ name: IDL.Text, category: IDL.Text, price: IDL.Nat64, payload: IDL.Vec(IDL.Nat8) });
export type Item = { name: string; category: string; price: bigint; payload: Uint8Array };
export const encodeItem = (i: Item): Uint8Array => new Uint8Array(IDL.encode([ItemIdl], [i]));
export const decodeItem = (b: Uint8Array): Item => {
  const [i] = IDL.decode([ItemIdl], b) as any[];
  return { ...i, payload: new Uint8Array(i.payload) };
};
export const IX = { byPrice: 1, byCategoryPrice: 2, byName: 3 } as const;
