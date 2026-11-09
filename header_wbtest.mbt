// Header tests.
//
// The fixtures under `internal/fixtures` are produced by dtc 1.8.1 and checked
// in, so these tests run without dtc installed. `tools/gen-fixtures.sh`
// regenerates them and asserts the checked-in copy still matches.

///|
/// The smallest blob that dtc emits for a node tree with a couple of
/// properties.
fn fixture_minimal() -> Bytes raise {
  @fs.read_file_to_bytes("internal/fixtures/minimal.dtb")
}

///|
/// Reads the header of a real blob and checks each field against the values a
/// hex dump of the same file shows.
test "header of a dtc-produced blob" {
  let h = parse_header(fixture_minimal())
  inspect(h.totalsize, content="357")
  inspect(h.off_dt_struct, content="56")
  inspect(h.off_dt_strings, content="288")
  inspect(h.off_mem_rsvmap, content="40")
  inspect(h.size_dt_struct, content="232")
  inspect(h.size_dt_strings, content="69")
  inspect(h.version, content="17")
  inspect(h.last_comp_version, content="16")
  inspect(h.boot_cpuid_phys, content="0")
}

///|
/// A blob whose magic is not `0xd00dfeed` has to be refused before any size
/// field is trusted.
test "magic is checked first" {
  let bytes = fixture_minimal()
  let damaged = Buffer::Buffer(size_hint=bytes.length())
  for i in 0..<bytes.length() {
    damaged.write_byte(if i == 0 { 0xAA } else { bytes.at(i) })
  }
  let out = try {
    let _ = parse_header(damaged.to_bytes())
    "accepted"
  } catch {
    e => e.to_string()
  }
  inspect(out, content="not a device tree blob: magic 0xaa0dfeed")
}

///|
/// A buffer shorter than the header must report how much was available, not
/// read past the end.
test "truncated blob" {
  let bytes = fixture_minimal()
  let short = Bounds::of_bytes(bytes).slice(0L, 20L, "prefix")
  let out = try {
    let _ = parse_header(short)
    "accepted"
  } catch {
    e => e.to_string()
  }
  inspect(
    out,
    content="unexpected end at offset 0: needed 40 bytes, 20 available",
  )
}
