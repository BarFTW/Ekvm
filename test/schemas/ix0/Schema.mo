/// Test schema with the first 0 demo index(es) (instruction-overhead bench).
import D "../Demo";
import S "../../../src/Schema";

module {
  public let schema : S.Schema<D.Item> = { version = 0; decode = D.decode; indexes = [] };
};
