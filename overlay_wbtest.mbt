// Overlay tests.
//
// Building an overlay is the half of the feature that dtc can check directly:
// the plugin source compiles to a blob with `__fixups__` in it, and dtc
// produces the same bytes for the same source with -@.

///|
/// Builds an overlay from a fixture and encodes it.
fn build_fixture(name : String) -> Bytes raise {
  let src = @fs.read_file_to_string("internal/fixtures/" + name)
  let file = parse_source(src)
  encode_blob(build_overlay(file))
}

///|
/// The overlay fixture, byte for byte against `dtc -@ -I dts -O dtb`.
///
/// This is the one test that says the fixup layout is right: an overlay whose
/// `__fixups__` entries name the wrong property or the wrong byte offset still
/// loads, and patches the wrong word.
test "overlay: byte-identical to dtc" {
  let mine = build_fixture("overlay-uart.dts")
  let theirs = @fs.read_file_to_bytes("internal/fixtures/overlay-uart.dtbo")
  inspect(first_difference(mine, theirs), content="identical")
}

///|
/// A plugin that is not marked `/plugin/` is not an overlay.
test "not a plugin" {
  let out = try {
    let file = parse_source("/dts-v1/; / { };")
    let _ = build_overlay(file)
    "built"
  } catch {
    e => e.to_string()
  }
  inspect(out, content="bad fixup: source is not marked /plugin/")
}
