/// Test schema with the first 2 demo index(es) (instruction-overhead bench).
import D "../Demo";
import S "../../../src/Schema";

module {
  public let schema : S.Schema<D.Item> = { version = 2; decode = D.decode; indexes = [D.byPrice, D.byCategoryPrice] };
};
