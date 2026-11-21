// Emitting a decoded tree as device tree source.
//
// The output matches what `dtc -I dtb -O dts` prints, byte for byte, because
// that is the only form a reader can check without reimplementing dtc's
// formatting rules. The rules that matter:
//
//   - tab indentation, one level per node
//   - properties before children, in the order the blob lists them
//   - a blank line after the last property of a node that has children, and
//     after the final property of the root
//   - cell values in hex with an `0x` prefix and at least two digits
//   - strings quoted, with the escapes dtc produces
//
// Byte equality with dtc is what the tests assert. Anything that differs is a
// formatting decision this module got wrong, since the tree itself is already
// verified by the read path.

///|
/// Renders a tree as source, the way `dtc -I dtb -O dts` would.
pub fn emit_source(tree : Tree) -> String {
  let buf = StringBuilder()
  buf.write_string("/dts-v1/;\n\n")
  // dtc prints the reservations between the version line and the root, each as
  // `/memreserve/<tab>0x%016x 0x%016x;`. Both halves are zero-padded to 16
  // digits, unlike cells, because a reservation is an address rather than a
  // value and a short form would read as a different address.
  for (address, size) in tree.memreserves {
    buf.write_string("/memreserve/\t0x\{pad16(address)} 0x\{pad16(size)};\n")
  }
  let labels = label_map(tree.root)
  emit_node(tree.root, "", "/", labels, buf)
  // `emit_node` already ends the root with `};\n`, so nothing is added here.
  // dtc's output ends exactly there, and an extra newline would make the byte
  // comparison fail on the last line alone.
  buf.to_string()
}

///|
/// Recovers node labels from `/__symbols__`.
///
/// A blob does not store labels on the nodes themselves; dtc writes them into
/// `/__symbols__` as `label = "/path"` entries when the source was compiled with
/// `-@`. Printing them back is what makes the output usable as an overlay
/// source: without a label there is no `&name` to write a reference with, so a
/// round trip through decompile would silently produce a tree that can no longer
/// be patched.
///
/// The map is keyed by the node path with a leading `/`, because that is the
/// form the entry holds. The root's own labels are keyed by `/` alone.
fn label_map(root : Node) -> Map[String, Array[String]] {
  let out : Map[String, Array[String]] = Map([])
  for child in root.children {
    if child.name != "__symbols__" {
      continue
    }
    for prop in child.properties {
      // The value is one NUL-terminated string holding the path.
      let bytes = Bounds::of_bytes(prop.value)
      let (path, _) = bytes.cstr(0L, bytes.length()) catch { _ => continue }
      match out.get(path) {
        Some(names) => names.push(prop.name)
        None => out.set(path, [prop.name])
      }
    }
  }
  out
}

///|
/// Writes one node and everything under it.
///
/// `indent` is the whitespace prefix for this node's own line; its properties
/// and children get one more tab.
fn emit_node(
  node : Node,
  indent : String,
  path : String,
  labels : Map[String, Array[String]],
  buf : StringBuilder,
) -> Unit {
  let inner = indent + "\t"
  let name = if node.name == "" { "/" } else { node.name }
  // dtc prints the labels in the reverse of the order `__symbols__` lists them,
  // which is the reverse of the order they appeared in the source. The map is
  // built in file order, so this walks backwards.
  let prefix = match labels.get(path) {
    Some(names) => {
      let buf2 = StringBuilder()
      let mut i = names.length() - 1
      while i >= 0 {
        buf2.write_string(names[i] + ": ")
        i = i - 1
      }
      buf2.to_string()
    }
    None => ""
  }
  buf.write_string(indent + prefix + name + " {\n")
  for prop in node.properties {
    buf.write_string(inner + prop.name)
    let value = render_value(prop.value)
    if value == "" {
      // A zero-length value is a boolean property: present means true, and dtc
      // prints it without `=` or a value.
      buf.write_string(";\n")
    } else {
      buf.write_string(" = " + value + ";\n")
    }
  }
  if node.children.length() > 0 {
    buf.write_string("\n")
    let mut first = true
    for child in node.children {
      if !first {
        buf.write_string("\n")
      }
      first = false
      let child_path = if path == "/" {
        "/" + child.name
      } else {
        path + "/" + child.name
      }
      emit_node(child, inner, child_path, labels, buf)
    }
  }
  buf.write_string(indent + "};\n")
}

///|
/// Renders a property value: a string, a cell list, or a byte string.
///
/// The decision is made from the bytes because a blob does not record which
/// kind a property is. dtc uses the same rule: a value ending in NUL whose
/// body is printable ASCII is a string, a value that is not a multiple of four
/// bytes is a byte string, and everything else is cells.
fn render_value(value : Bytes) -> String {
  let n = value.length()
  if n == 0 {
    return ""
  }
  if is_string(value) {
    return quote(value)
  }
  if n % 4 != 0 {
    return byte_string(value)
  }
  cell_list(value)
}

///|
/// Whether a value is one or more NUL-terminated printable strings.
///
/// Interior NULs just start the next string, and `quote` prints those as
/// comma-separated quoted strings. The test is therefore: every byte is
/// printable or NUL, and the last one is NUL. Requiring the whole body to be
/// printable would reject `"a", "b"`, which a blob stores as `a\0b\0`.
fn is_string(value : Bytes) -> Bool {
  let n = value.length()
  if n == 0 || value.at(n - 1).to_int() != 0 {
    return false
  }
  let mut printable_count = 0
  for i in 0..<n {
    let b = value.at(i).to_int()
    let printable = b >= 0x20 && b <= 0x7E
    if !printable && b != 0 {
      return false
    }
    if printable {
      printable_count = printable_count + 1
    }
  }
  // `<0x00>` is four zero bytes and looks like a string of empty strings by
  // the test above; requiring at least one printable character separates a
  // real string from a zero cell.
  printable_count > 0
}

///|
/// Quotes a value that is one or more NUL-terminated strings.
///
/// Interior NULs separate the strings, matching how `compatible = "a", "b"` is
/// stored: one value with two terminators, not two values.
fn quote(value : Bytes) -> String {
  let buf = StringBuilder()
  let mut start = 0
  let mut first = true
  for i in 0..<value.length() {
    if value.at(i).to_int() == 0 {
      if !first {
        buf.write_string(", ")
      }
      first = false
      buf.write_string("\"")
      for j in start..<i {
        let c = value.at(j).to_int()
        if c == 0x22 {
          buf.write_string("\\\"")
        } else if c == 0x5C {
          buf.write_string("\\\\")
        } else {
          buf.write_char(c.unsafe_to_char())
        }
      }
      buf.write_string("\"")
      start = i + 1
    }
  }
  buf.to_string()
}

///|
/// Renders a value as a cell list in hex.
fn cell_list(value : Bytes) -> String {
  let buf = StringBuilder()
  buf.write_string("<")
  let count = value.length() / 4
  for i in 0..<count {
    if i > 0 {
      buf.write_string(" ")
    }
    let at = i * 4
    let raw = (value.at(at).to_int().to_uint64() << 24) |
      (value.at(at + 1).to_int().to_uint64() << 16) |
      (value.at(at + 2).to_int().to_uint64() << 8) |
      value.at(at + 3).to_int().to_uint64()
    buf.write_string(hex_cell(raw))
  }
  buf.write_string(">")
  buf.to_string()
}

///|
/// Formats a cell as `0x` plus hex, with at least two digits.
///
/// Two digits rather than one is what dtc does: `reg = <0x00 0x1000>`. A cell
/// whose high bytes are non-zero gets as many digits as it needs.
fn hex_cell(v : UInt64) -> String {
  let digits = "0123456789abcdef"
  // Everything here works on the low 32 bits, because that is what a cell is.
  // Masking before the conversion keeps the bit pattern: a cell with bit 31
  // set would otherwise not fit in a signed `Int` and the digits come out
  // wrong. The nibble count reads `cell`, not `v`, so a caller that passes a
  // wider value gets the low half printed rather than a run of leading zeroes.
  let cell = v & 0xFFFF_FFFFUL
  let raw = cell.to_int()
  // Count nibbles from the top: shift right until nothing is left, which is
  // the only way to know how many digits the value needs.
  let mut nibbles = 1
  let mut probe = cell
  while probe > 0xFUL {
    probe = probe >> 4
    nibbles = nibbles + 1
  }
  // dtc pads to two digits so that a cell reads as a byte: `<0x00>`, not
  // `<0x0>`. Above that it uses the natural width, with no rounding to an even
  // count.
  let width = if nibbles < 2 { 2 } else { nibbles }
  let buf = StringBuilder()
  buf.write_string("0x")
  for i in 0..<width {
    let shift = (width - 1 - i) * 4
    let nibble = (raw >> shift) & 0xF
    buf.write_char(digits.get_char(nibble).unwrap())
  }
  buf.to_string()
}

///|
/// Renders a value as a byte string: hex pairs in brackets.
fn byte_string(value : Bytes) -> String {
  let digits = "0123456789abcdef"
  let buf = StringBuilder()
  buf.write_string("[")
  for i in 0..<value.length() {
    if i > 0 {
      buf.write_string(" ")
    }
    let b = value.at(i).to_int()
    buf.write_char(digits.get_char((b >> 4) & 0xF).unwrap())
    buf.write_char(digits.get_char(b & 0xF).unwrap())
  }
  buf.write_string("]")
  buf.to_string()
}

///|
/// Formats a 64-bit value as 16 lowercase hex digits, no `0x`.
///
/// `/memreserve/` lines in dtc's output always carry the full width. A cell
/// gets the natural width instead, but a reservation is an address, and a
/// reader comparing two dumps would see `0x1000` and `0x0000000000001000` as
/// different when they name the same place.
fn pad16(v : UInt64) -> String {
  let digits = "0123456789abcdef"
  let buf = StringBuilder()
  // Split into two 32-bit halves, because a shift count on `UInt64` here has
  // to be a `UInt` and an `Int` only holds 32 bits. Each half is then printed
  // eight nibbles at a time from a mask.
  let hi = ((v >> 32) & 0xFFFF_FFFFUL).to_int()
  let lo = (v & 0xFFFF_FFFFUL).to_int()
  for half in [hi, lo] {
    for i in 0..<8 {
      let shift = (7 - i) * 4
      let nibble = (half >> shift) & 0xF
      buf.write_char(digits.get_char(nibble).unwrap())
    }
  }
  buf.to_string()
}
