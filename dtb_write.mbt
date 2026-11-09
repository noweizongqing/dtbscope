// Encoding a node tree into the flattened blob format.
//
// The writer is the inverse of `header.mbt` and `struct_block.mbt`: it lays out
// the four blocks in the order the format requires and fills in the size
// fields afterwards, since every offset depends on sizes that are only known
// once the blocks are built.
//
// Property names are deduplicated through a string table. dtc emits each name
// once, at the position of its first use, and later properties point back at
// it; matching that order is what makes the output byte-identical rather than
// merely equivalent.

///|
/// A name table for the strings block.
///
/// Insertion order matters: dtc writes a name the first time it appears and
/// never moves it, so a tree encoded in source order reproduces the same block
/// layout. A hash map alone would not, which is why the offsets are also kept
/// in a list.
pub(all) struct StringTable {
  /// Bytes accumulated so far, NUL-terminated entries.
  bytes : Buffer
  /// Offsets keyed by name.
  offsets : Map[String, Int32]
}

///|
/// Creates an empty table.
pub fn StringTable::new() -> StringTable {
  { bytes: Buffer(), offsets: Map([]), }
}

///|
/// Returns the offset of `name`, appending it if it is not present yet.
fn StringTable::intern(self : StringTable, name : String) -> Int32 {
  match self.offsets.get(name) {
    Some(at) => at
    None => {
      let at = self.bytes.length()
      for i in 0..<name.length() {
        self.bytes.write_byte(name.get_char(i).unwrap().to_int().to_byte())
      }
      self.bytes.write_byte((0 : Int32).to_byte())
      self.offsets.set(name, at)
      at
    }
  }
}

///|
/// The encoded string block.
fn StringTable::to_bytes(self : StringTable) -> Bytes {
  self.bytes.to_bytes()
}

///|
/// Writes a big-endian 32-bit word.
fn put_u32(out : Buffer, v : UInt32) -> Unit {
  let raw = v.reinterpret_as_int()
  out.write_byte(((raw >> 24) & 0xFF).to_byte())
  out.write_byte(((raw >> 16) & 0xFF).to_byte())
  out.write_byte(((raw >> 8) & 0xFF).to_byte())
  out.write_byte((raw & 0xFF).to_byte())
}

///|
/// Writes a big-endian 32-bit word from a cell value.
fn put_cell(out : Buffer, v : UInt64) -> Unit {
  let value = (v & 0xFFFF_FFFFUL).to_int()
  out.write_byte(((value >> 24) & 0xFF).to_byte())
  out.write_byte(((value >> 16) & 0xFF).to_byte())
  out.write_byte(((value >> 8) & 0xFF).to_byte())
  out.write_byte((value & 0xFF).to_byte())
}

///|
/// Pads the buffer to a 4-byte boundary with NUL.
fn align_buffer(out : Buffer) -> Unit {
  while out.length() % 4 != 0 {
    out.write_byte((0 : Int32).to_byte())
  }
}

///|
/// Encodes one property value into the byte form the blob stores.
///
/// Values are concatenated in source order with no separator, which is what
/// makes `compatible = "a", "b"` come out as one string table entry rather
/// than two cells. Strings keep their trailing NUL; cells widen to 32 or 64
/// bits depending on the part; a reference has no encoding yet and is refused
/// here so that a caller cannot silently get a wrong blob.
fn encode_value(parts : Array[ValuePart], out : Buffer) -> Unit raise DtbError {
  for part in parts {
    match part {
      Text(s) => {
        for i in 0..<s.length() {
          out.write_byte(s.get_char(i).unwrap().to_int().to_byte())
        }
        out.write_byte((0 : Int32).to_byte())
      }
      Cells(cells) =>
        for c in cells {
          put_cell(out, c)
        }
      TypedCells(width, cells) =>
        for c in cells {
          match width {
            8UL => out.write_byte((c.to_int() & 0xFF).to_byte())
            16UL => {
              let v = c.to_int() & 0xFFFF
              out.write_byte(((v >> 8) & 0xFF).to_byte())
              out.write_byte((v & 0xFF).to_byte())
            }
            32UL => put_cell(out, c)
            _ => {
              let raw = c.to_int()
              for shift in [56, 48, 40, 32, 24, 16, 8, 0] {
                out.write_byte(((raw >> shift) & 0xFF).to_byte())
              }
            }
          }
        }
      Bytes(bs) =>
        for b in bs {
          out.write_byte(b)
        }
      Ref(label) =>
        raise Unsupported(
          what="reference &\{label}, call resolve_references first",
        )
      PathRef(path) =>
        raise Unsupported(
          what="path reference &\{path}, call resolve_references first",
        )
      Refs(_) => raise Unsupported(what="cell list containing a reference")
    }
  }
}

///|
/// Emits a node and its descendants into the struct block.
///
/// Order is properties first, then children, which is what the format requires
/// and what dtc produces. A child's `BEGIN_NODE` comes after its parent's
/// properties so a reader can attach properties as it walks without buffering.
fn write_node(
  node : SourceNode,
  strings : StringTable,
  out : Buffer,
) -> Unit raise DtbError {
  put_u32(out, 0x1)
  // The root node is named by the empty string, matching `/` in the source.
  for i in 0..<node.name.length() {
    out.write_byte(node.name.get_char(i).unwrap().to_int().to_byte())
  }
  out.write_byte((0 : Int32).to_byte())
  align_buffer(out)
  for prop in node.properties {
    // The value is encoded first so that its length can be written ahead of
    // it. A `Buffer` cannot be rewritten in place, and reserving a word to
    // patch later would need that; encoding first costs one temporary buffer
    // per property and keeps `Buffer` as the only writer.
    let body = Buffer()
    encode_value(prop.value.parts, body)
    let value = body.to_bytes()
    let name_at = strings.intern(prop.name)
    put_u32(out, 0x3)
    put_u32(out, value.length().reinterpret_as_uint())
    put_u32(out, name_at.reinterpret_as_uint())
    for i in 0..<value.length() {
      out.write_byte(value.at(i))
    }
    align_buffer(out)
  }
  for child in node.children {
    write_node(child, strings, out)
  }
  put_u32(out, 0x2)
}

///|
/// Encodes a source tree as a blob.
///
/// The four blocks are laid out in the order the format fixes: header,
/// memory reservation map, struct block, strings block. Sizes are written
/// last, once the blocks exist.
///
/// References must already be resolved. Encoding refuses a tree that still
/// contains one, because a reference has no byte form: the whole point of
/// phandles is that the encoder decided the number.
pub fn encode_blob(file : SourceFile) -> Bytes raise DtbError {
  let strings = StringTable::new()
  let struct_block = Buffer()
  write_node(file.root, strings, struct_block)
  put_u32(struct_block, 0x9)
  let strings_bytes = strings.to_bytes()
  let memreserve = Buffer()
  for (address, size) in file.memreserves {
    put_u64(memreserve, address)
    put_u64(memreserve, size)
  }
  // The map ends with an all-zero entry, which is also what an empty map is.
  put_u64(memreserve, 0UL)
  put_u64(memreserve, 0UL)
  let struct_bytes = struct_block.to_bytes()
  let memreserve_bytes = memreserve.to_bytes()
  let blocks = memreserve_bytes.length() + struct_bytes.length()
  let total = 40 + blocks + strings_bytes.length()
  let out = Buffer()
  put_u32(out, 0xD00D_FEED)
  put_u32(out, total.reinterpret_as_uint())
  let off_struct = 40 + memreserve_bytes.length()
  put_u32(out, off_struct.reinterpret_as_uint())
  let off_strings = off_struct + struct_bytes.length()
  put_u32(out, off_strings.reinterpret_as_uint())
  put_u32(out, 40)
  put_u32(out, 17)
  put_u32(out, 16)
  put_u32(out, 0)
  put_u32(out, strings_bytes.length().reinterpret_as_uint())
  put_u32(out, struct_bytes.length().reinterpret_as_uint())
  for i in 0..<memreserve_bytes.length() {
    out.write_byte(memreserve_bytes.at(i))
  }
  for i in 0..<struct_bytes.length() {
    out.write_byte(struct_bytes.at(i))
  }
  for i in 0..<strings_bytes.length() {
    out.write_byte(strings_bytes.at(i))
  }
  out.to_bytes()
}

///|
/// Writes a big-endian 64-bit value.
fn put_u64(out : Buffer, v : UInt64) -> Unit {
  let raw = v.to_int()
  for shift in [56, 48, 40, 32, 24, 16, 8, 0] {
    out.write_byte(((raw >> shift) & 0xFF).to_byte())
  }
}
