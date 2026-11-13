/// Default shard schema: no secondary indexes. Copy this package and pass it
/// to moc as `--package ekvm-schema <dir>` to compile your own indexes in.
import S "../../src/Schema";

module {
  public let schema : S.Schema<Blob> = S.empty;
};
