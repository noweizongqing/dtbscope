// Tree dump: the flat `path` / `property = value` reading.
//
// Distinct from `dts_emit`, which produces source that dtc can compile back.
// This one is a reading aid: every property on its own line under its node
// path, values shown as cells or a quoted string, with no attempt at syntax.
// It lives in the library rather than in each front end because the command
// line and the browser module both need it, and two copies of a formatter
// drift: the first version of the browser copy silently dropped the tail of a
// value that was not a whole number of cells.

///|
/// Renders a whole tree, one line per node and property.
///
/// Node paths start at `/`; properties are indented two spaces under them.
/// Structural warnings the parser tolerated are appended as `# warning:`
/// lines, so a viewer sees them next to the tree rather than not at all.
pub fn dump_tree(tree : Tree) -> String {
  let buf = StringBuilder()
  dump_node(tree.root, "/", buf)
  for w in tree.warnings {
    buf.write_string("# warning: " + w.to_string() + "\n")
  }
  buf.to_string()
}

///|
/// Writes a node and its descendants as `path` lines with indented properties.
fn dump_node(node : Node, path : String, buf : StringBuilder) -> Unit {
  buf.write_string(path + "\n")
  for p in node.properties {
    buf.write_string("  " + p.name + " = " + dump_value(p.value) + "\n")
  }
  for c in node.children {
    let child_path = if path == "/" {
      "/" + c.name
    } else {
      path + "/" + c.name
    }
    dump_node(c, child_path, buf)
  }
}

///|
/// Renders a property value as a cell list or a quoted string.
///
/// The rule for "is this a string" is dtc's: it ends in NUL and everything
/// before the NUL is printable ASCII. Everything else prints as cells, and a
/// tail shorter than a cell prints as hex bytes after them — dropping that tail
/// would hide the last bytes of a value whose length is not a multiple of four,
/// which `compatible = "arm,realview-pb1176", "arm,realview"` is.
fn dump_value(value : Bytes) -> String {
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
      // rather than sign-extending to a value near 2^64.
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
    if at < n {
      // A tail shorter than a word is a byte string, printed as hex.
      buf.write_string(" bytes:")
      while at < n {
        let b = value.at(at).to_int()
        buf.write_char(hex_digit((b >> 4) & 0xF))
        buf.write_char(hex_digit(b & 0xF))
        at = at + 1
      }
    }
    buf.write_string(">")
    buf.to_string()
  }
}

///|
/// One hex digit as a character.
fn hex_digit(n : Int32) -> Char {
  if n < 10 {
    (0x30 + n).unsafe_to_char()
  } else {
    (0x61 + n - 10).unsafe_to_char()
  }
}
