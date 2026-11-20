// Tree dump tests.
//
// The dump is a reading aid rather than source, so there is no dtc output to
// compare against. What it has to get right is that it shows every byte of
// every value: the first version of the browser copy dropped the tail of any
// value whose length was not a multiple of four, and a `compatible` string
// list is exactly that shape.

///|
/// Reads a fixture's tree.
fn dumped(name : String) -> Tree raise {
  @fs.read_file_to_bytes("internal/fixtures/" + name) |> parse_tree
}

///|
/// The three properties of the minimal fixture, on their own lines under `/`.
test "dump: node and property lines" {
  let text = dump_tree(dumped("minimal.dtb"))
  inspect(text.contains("/\n"), content="true")
  inspect(text.contains("  compatible = "), content="true")
  inspect(text.contains("  #address-cells = <1>"), content="true")
}

///|
/// A value whose length is not a whole number of cells prints its tail.
///
/// The RealView `compatible` is `"arm,realview-pb1176\0arm,realview\0"`, 28
/// bytes: seven cells exactly, so that one happens not to need a tail. The
/// case that does is a value with a remainder, and the dump has to show it —
/// silently rounding down loses the last bytes of the value, which for a
/// compatible list means losing a device name.
test "dump: a value with a tail shows the tail" {
  let value = Bytes::from_array([0x61, 0x62, 0x63, 0x64, 0x65, 0x66])
  let text = dump_value(value)
  inspect(text, content="<1633837924 bytes:6566>")
}

///|
/// A value that is a whole number of cells has no `bytes:` marker: the tail is
/// only printed when there is one, not as an empty suffix on every cell list.
test "dump: whole cells have no tail" {
  let value = Bytes::from_array([0x00, 0x00, 0x00, 0x02])
  inspect(dump_value(value), content="<2>")
}

///|
/// A string value prints quoted, without the trailing NUL.
test "dump: string value" {
  let value = Bytes::from_array([0x6f, 0x6b, 0x61, 0x79, 0x00])
  inspect(dump_value(value), content="\"okay\"")
}

///|
/// An empty value prints as an empty cell list rather than as an empty string,
/// because a blob stores a boolean property as zero bytes and the dump should
/// not claim it was `""`.
test "dump: empty value" {
  inspect(dump_value(Bytes::make(0, b'\x00')), content="<>")
}

///|
/// A cell with bit 31 set prints as its unsigned value.
///
/// Accumulating the four bytes in a signed `Int` gives -1 for `ffffffff`, and
/// a phandle or a base address at the top of the range would print as a
/// negative number.
test "dump: top bit set" {
  let value = Bytes::from_array([0xFF, 0xFF, 0xFF, 0xFF])
  inspect(dump_value(value), content="<4294967295>")
}
