// Encoder tests.
//
// The comparison is byte-for-byte against dtc's output for the same source.
// That is a much stronger claim than "the blob parses back", and it is the one
// the project's output quality rests on: if these tests pass, anything that
// accepts dtc's blobs accepts ours.

///|
/// Parses a fixture's DTS source and encodes it.
fn encode_fixture(name : String) -> Bytes raise {
  let src = @fs.read_file_to_string("internal/fixtures/" + name)
  let file = parse_source(src)
  // References have to be resolved before encoding: they carry no bytes.
  encode_blob(resolve_references(file))
}

///|
/// Reads the DTB dtc produced for the same source.
fn fixture_blob(name : String) -> Bytes raise {
  @fs.read_file_to_bytes("internal/fixtures/" + name)
}

///|
/// Reports the first differing byte as a hex pair with its offset, or a
/// message about the lengths. A whole-buffer diff would print hundreds of
/// bytes and hide where the divergence starts.
fn first_difference(a : Bytes, b : Bytes) -> String {
  let common = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<common {
    if a.at(i) != b.at(i) {
      return "byte \{i}: mine 0x\{hex_byte(a.at(i))}, dtc 0x\{hex_byte(b.at(i))}"
    }
  }
  if a.length() != b.length() {
    "lengths differ: mine \{a.length()}, dtc \{b.length()}"
  } else {
    "identical"
  }
}

///|
/// Formats a byte as two hex digits. Duplicated from the test helper in
/// `dts_parse_wbtest.mbt` because whitebox test files are separate packages.
fn hex_byte(b : Byte) -> String {
  let digits = "0123456789abcdef"
  let n = b.to_int()
  let buf = StringBuilder()
  buf.write_char(digits.get_char((n >> 4) & 0xF).unwrap())
  buf.write_char(digits.get_char(n & 0xF).unwrap())
  buf.to_string()
}

///|
/// The flat fixture, byte for byte.
test "minimal: byte-identical to dtc" {
  let mine = encode_fixture("minimal.dts")
  let theirs = fixture_blob("minimal.dtb")
  inspect(first_difference(mine, theirs), content="identical")
}

///|
/// The nested fixture, byte for byte. This one exercises the string table:
/// `compatible` and `device_type` repeat across nodes and have to be
/// interned once.
test "nested: byte-identical to dtc" {
  let mine = encode_fixture("nested.dts")
  let theirs = fixture_blob("nested.dtb")
  inspect(first_difference(mine, theirs), content="identical")
}

///|
/// What the encoder writes has to parse back through the reader, and the
/// resulting tree has to match the source shape. Round-tripping through the
/// binary form catches a mistake the byte comparison would also catch, but
/// says which side is wrong.
test "our output parses back" {
  let mine = encode_fixture("nested.dts")
  let header = parse_header(mine)
  let struct_bounds = Bounds::of_range(
    mine,
    header.off_dt_struct,
    header.off_dt_struct + header.size_dt_struct,
  )
  let strings_bounds = Bounds::of_range(
    mine,
    header.off_dt_strings,
    header.off_dt_strings + header.size_dt_strings,
  )
  let tree = parse_struct(struct_bounds, strings_bounds)
  inspect(tree.warnings.length(), content="0")
  inspect(tree.root.children.length(), content="4")
}

///|
/// An unresolved reference has no byte form, so encoding must refuse it rather
/// than emit a placeholder word. This guards the order of the two passes: a
/// caller that encodes a freshly parsed tree gets a loud failure instead of a
/// blob whose reference word is zero.
test "reference is refused before resolution" {
  let src =
    #|/dts-v1/;
    #|/ {
    #|  clk: clock { };
    #|  dev { parent = <&clk>; };
    #|};
  let out = try {
    let file = parse_source(src)
    let _ = encode_blob(file)
    "encoded"
  } catch {
    e => e.to_string()
  }
  inspect(out, content="unsupported: cell list containing a reference")
}

///|
/// An empty memory reservation map still needs its terminating zero entry.
test "memreserve terminator" {
  let src = "/dts-v1/; / { };"
  let mine = encode_blob(parse_source(src))
  let header = parse_header(mine)
  inspect(header.off_mem_rsvmap, content="40")
  inspect(header.off_dt_struct, content="56")
}

///|
/// A declared reservation shows up in the map.
test "memreserve is encoded" {
  let src =
    #|/dts-v1/;
    #|/memreserve/ 0x10000000 0x4000;
    #|/ { };
  let mine = encode_blob(parse_source(src))
  let header = parse_header(mine)
  inspect(header.off_dt_struct, content="72")
}

///|
/// A real board from the Linux tree: ARM RealView PB1176, 68 nodes, 14
/// phandles, aliases, dma-ranges and a 1000-byte string table.
///
/// This is the fixture that matters most. The two hand-written ones agree with
/// dtc on everything they happen to contain; this one contains what a board
/// actually has, and it was the file that showed the phandle numbering rule:
/// a tree walk gives each referenced node a different number than dtc, and the
/// blob stays structurally valid either way.
///
/// The source is the preprocessed form. The file in the kernel tree starts
/// with `#include`, and cpp has to run before either tool sees it; the
/// `.pre.dts` here is that output, so the comparison does not depend on which
/// cpp or which header revisions the machine happens to have.
test "realview pb1176: byte-identical to dtc" {
  let mine = encode_fixture("realview-pb1176.pre.dts")
  let theirs = fixture_blob("realview-pb1176.dtb")
  inspect(first_difference(mine, theirs), content="identical")
}

///|
/// The real fixture has to be large enough to be worth trusting: a tiny file
/// would pass the comparison without exercising much.
test "realview pb1176: shape" {
  let mine = encode_fixture("realview-pb1176.pre.dts")
  let header = parse_header(mine)
  inspect(header.totalsize, content="9983")
  inspect(header.size_dt_struct, content="9096")
  inspect(header.size_dt_strings, content="831")
}

///|
/// Encoding a decoded tree reproduces the blob it came from, byte for byte.
///
/// This is the path `dtbscope -b base.dtb -o merged.dtb` takes after its merge:
/// `apply_overlay` patches a decoded `Tree`, and `encode_tree` writes it back.
/// Nothing else in the suite covers that function, which matters because the
/// merge path has no dtc comparison to fall back on — dtc has no apply mode —
/// so a bug here would show up as a loader refusing a blob rather than as a
/// failed test. Padding is the part that breaks first: a property whose value
/// is not a multiple of four has to be followed by zeroes, and dropping them
/// leaves every later property misaligned while the header still says the
/// block is the right length.
///
/// The strings block comes out in first-use order rather than the original
/// order, so this passes only on trees dtc wrote, which is the same invariant
/// `dts_emit` relies on for its own comparison.
test "encode_tree: round-trips every fixture" {
  let names = [
    "minimal.dtb", "nested.dtb", "overlay-base.dtb", "overlay-labels.dtb", "overlay-uart.dtbo",
    "realview-pb1176.dtb",
  ]
  for name in names {
    let blob = fixture_blob(name)
    let again = encode_tree(decode_blob(blob))
    inspect(first_difference(again, blob), content="identical")
  }
}

///|
/// Decodes a blob the way the CLI does, so the test covers the same path a
/// caller takes: `parse_tree` reads the header, both blocks and the
/// reservation map, while `parse_struct` on its own sees only the node tree.
fn decode_blob(blob : Bytes) -> Tree raise {
  parse_tree(blob)
}

///|
/// The reservation map holds 64-bit address and size, and both halves have to
/// survive.
///
/// The earlier test only checked that the block was the right length, which a
/// wrong address passes: the entry is still 16 bytes. The bug this catches is
/// that `UInt64::to_int` truncates by value, so a 64-bit write built from it
/// emitted the low half twice and a reservation at `0x1000` came out at
/// `0x1000_0000_1000`.
test "memreserve keeps 64-bit addresses" {
  let src =
    #|/dts-v1/;
    #|/memreserve/ 0x100000000 0x200000000;
    #|/ { };
  let mine = encode_blob(parse_source(src))
  let bounds = Bounds::of_bytes(mine)
  // The map starts at the header's fixed offset of 40.
  let (address, after_addr) = bounds.read_u64(Cursor::big(40L))
  let (size, _) = bounds.read_u64(after_addr)
  inspect(address, content="4294967296")
  inspect(size, content="8589934592")
}

///|
/// `/bits/ 64` writes both halves of the value.
///
/// A 64-bit cell is the one width where the low half alone is not a plausible
/// answer: the high half is the part that gets lost, and a value with both
/// halves distinct shows it.
test "bits 64 keeps both halves" {
  let src = "/dts-v1/; / { a = /bits/ 64 <0x1234567890abcdef>; };"
  let blob = encode_blob(parse_source(src))
  let header = parse_header(blob)
  let struct_bounds = Bounds::of_range(
    blob,
    header.off_dt_struct,
    header.off_dt_struct + header.size_dt_struct,
  )
  let strings_bounds = Bounds::of_range(
    blob,
    header.off_dt_strings,
    header.off_dt_strings + header.size_dt_strings,
  )
  let tree = parse_struct(struct_bounds, strings_bounds)
  let value = tree.root.properties[0].value
  inspect(value.length(), content="8")
  let read = Bounds::of_bytes(value)
  let (v, _) = read.read_u64(Cursor::big(0L))
  inspect(v, content="1311768467294899695")
}

///|
/// A reservation survives decoding and re-encoding.
///
/// `Tree` used to carry only the node tree, so `encode_tree` rebuilt the
/// reservation map as a bare terminator and the blob came back shorter. It
/// still parsed, and no test looked at the length, so a merge that passed
/// reservations through would have dropped them silently.
test "encode_tree keeps reservations" {
  let src =
    #|/dts-v1/;
    #|/memreserve/ 0x1000 0x100;
    #|/memreserve/ 0x200000000 0x400;
    #|/ { };
  let original = encode_blob(parse_source(src))
  let again = encode_tree(parse_tree(original))
  inspect(first_difference(again, original), content="identical")
}

///|
/// The reservation map reaches the emitted source, in dtc's format.
///
/// Both halves print as 16 hex digits with a tab after `/memreserve/`, and
/// there is no blank line between the last reservation and the root node.
test "emit_source prints reservations" {
  let src =
    #|/dts-v1/;
    #|/memreserve/ 0x1000 0x100;
    #|/ { };
  let text = emit_source(parse_tree(encode_blob(parse_source(src))))
  inspect(
    text.contains("/memreserve/\t0x0000000000001000 0x0000000000000100;\n/ {"),
    content="true",
  )
}
