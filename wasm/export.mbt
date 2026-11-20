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
  let text = render(blob) catch { e => "!" + e.to_string() }
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
/// Formats a tree, one line per node and property.
fn render(blob : Bytes) -> String raise {
  let tree = @lib.parse_tree(blob)
  let buf = StringBuilder()
  render_node(tree.root, "/", buf)
  for w in tree.warnings {
    buf.write_string("# warning: " + w.to_string() + "\n")
  }
  buf.to_string()
}

///|
/// Writes a node and its descendants.
fn render_node(node : @lib.Node, path : String, buf : StringBuilder) -> Unit {
  buf.write_string(path + "\n")
  for p in node.properties {
    buf.write_string("  " + p.name + " = " + render_value(p.value) + "\n")
  }
  for c in node.children {
    let child_path = if path == "/" {
      "/" + c.name
    } else {
      path + "/" + c.name
    }
    render_node(c, child_path, buf)
  }
}

///|
/// Renders a property value as text or cells, whichever the bytes support.
///
/// The same rule dtc uses when printing: a value is a string when it ends in
/// NUL and everything before it is printable ASCII.
fn render_value(value : Bytes) -> String {
  let n = value.length()
  if n == 0 {
    return "<>"
  }
  let mut is_text = value.at(n - 1).to_int() == 0
  if is_text {
    for i in 0..<(n - 1) {
      let b = value.at(i).to_int()
      if b < 0x20 || b > 0x7E {
        is_text = false
      }
    }
  }
  if is_text {
    let buf = StringBuilder()
    buf.write_string("\"")
    for i in 0..<(n - 1) {
      buf.write_char(value.at(i).to_int().unsafe_to_char())
    }
    buf.write_string("\"")
    buf.to_string()
  } else {
    let buf = StringBuilder()
    buf.write_string("<")
    let mut at = 0
    let mut first = true
    while at + 4 <= n {
      // Accumulated in UInt64 so a cell with bit 31 set prints as 0x80000000
      // rather than sign-extending.
      let raw = (value.at(at).to_int().to_uint64() << 24) |
        (value.at(at + 1).to_int().to_uint64() << 16) |
        (value.at(at + 2).to_int().to_uint64() << 8) |
        value.at(at + 3).to_int().to_uint64()
      if !first {
        buf.write_string(" ")
      }
      first = false
      buf.write_string(raw.to_string())
      at = at + 4
    }
    buf.write_string(">")
    buf.to_string()
  }
}
