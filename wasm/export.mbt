// WebAssembly entry points.
//
// A browser caller cannot pass MoonBit's own `Bytes` or `String` across the
// boundary directly, so each entry point here takes and returns the types
// JavaScript can hand over: byte arrays in, a UTF-8 byte array out. The
// caller allocates the input in this module's heap and reads the result back
// out of it.

///|
/// Renders a blob as a tree, or returns a message prefixed with `!`.
///
/// The prefix rather than a separate status channel keeps the boundary to one
/// function per operation: the caller checks the first byte rather than
/// coordinating two calls and a shared error slot.
pub fn dump_blob(blob : Bytes) -> Bytes {
  let text = @lib.dump_tree(@lib.parse_tree(blob)) catch {
    e => "!" + e.to_string()
  }
  @utf8.encode(text)
}

///|
/// Compiles DTS source to a blob, or returns a message prefixed with `!`.
pub fn compile_source(source : Bytes) -> Bytes {
  let out = try {
    let text = @utf8.decode(source)
    let file = @lib.parse_source(text)
    @lib.encode_blob(@lib.resolve_references(file))
  } catch {
    e => return @utf8.encode("!" + e.to_string())
  }
  out
}

///|
/// Renders a blob as device tree source, the way `dtc -I dtb -O dts` would.
///
/// Separate from `dump_blob` because the two answer different questions: the
/// dump is a reading aid with every property flattened, while this produces
/// text that `dtc` can compile back.
pub fn decompile_blob(blob : Bytes) -> Bytes {
  let text = @lib.emit_source(@lib.parse_tree(blob)) catch {
    e => "!" + e.to_string()
  }
  @utf8.encode(text)
}
