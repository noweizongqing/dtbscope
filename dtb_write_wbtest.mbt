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
