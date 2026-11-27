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

///|
/// Reads the base and overlay fixtures and applies the second to the first.
fn apply_fixtures() -> Tree raise {
  let base_bytes = @fs.read_file_to_bytes("internal/fixtures/overlay-base.dtb")
  let base = read_tree(base_bytes)
  let over_bytes = @fs.read_file_to_bytes("internal/fixtures/overlay-uart.dtbo")
  let over = parse_overlay(read_tree(over_bytes))
  apply_overlay(base, over)
}

///|
/// Decodes a blob into a tree.
fn read_tree(blob : Bytes) -> Tree raise {
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
  parse_struct(struct_bounds, strings_bounds)
}

///|
/// Walks to a node by path.
fn node_at(tree : Tree, path : String) -> Node raise {
  let mut current = tree.root
  for segment in split_segments(path) {
    let mut found = false
    for child in current.children {
      if child.name == segment {
        current = child
        found = true
      }
    }
    if !found {
      raise Failure("no node at \{path}")
    }
  }
  current
}

///|
/// Splits a path into its segments.
fn split_segments(path : String) -> Array[String] {
  let out : Array[String] = []
  let mut start = 0
  for i in 0..<path.length() {
    if path.get_char(i).unwrap() == '/' {
      if i > start {
        out.push(path[start:i].to_owned())
      }
      start = i + 1
    }
  }
  if path.length() > start {
    out.push(path[start:].to_owned())
  }
  out
}

///|
/// Reads a property value as a string.
fn prop_text(node : Node, name : String) -> String raise {
  for prop in node.properties {
    if prop.name == name {
      let value = Bounds::of_bytes(prop.value)
      let text = value.cstr(0L, value.length())
      return text.0
    }
  }
  raise Failure("no property \{name}")
}

///|
/// Reads a property value as one cell.
fn prop_cell(node : Node, name : String) -> Int32 raise {
  for prop in node.properties {
    if prop.name == name {
      let value = Bounds::of_bytes(prop.value)
      let read = value.read_u32(Cursor::big(0L))
      return read.0.reinterpret_as_int()
    }
  }
  raise Failure("no property \{name}")
}

///|
/// The whole point of an overlay: the base tree disabled the UART and the
/// overlay enables it, adding properties the base did not have.
test "applying the overlay enables the uart" {
  let merged = apply_fixtures()
  let uart = node_at(merged, "/soc/serial@2000")
  inspect(prop_text(uart, "status"), content="okay")
  inspect(prop_cell(uart, "clock-frequency"), content="115200")
  inspect(prop_cell(uart, "interrupts"), content="5")
}

///|
/// Properties the base tree set that the overlay did not mention have to
/// survive: this is what separates merging from replacing.
test "unmentioned properties survive the merge" {
  let merged = apply_fixtures()
  let uart = node_at(merged, "/soc/serial@2000")
  inspect(prop_text(uart, "compatible"), content="test,uart")
  // `reg` is two cells; check the first.
  inspect(prop_cell(uart, "reg"), content="8192")
}

///|
/// The reference to the interrupt controller resolves through the base tree's
/// `__symbols__` and the phandle it already had.
test "cross references resolve into the base tree" {
  let merged = apply_fixtures()
  let uart = node_at(merged, "/soc/serial@2000")
  let intc = node_at(merged, "/soc/interrupt-controller@1000")
  let intc_phandle = prop_cell(intc, "phandle")
  inspect(prop_cell(uart, "interrupt-parent"), content="1")
  inspect(intc_phandle, content="1")
}

///|
/// A base tree built without -@ has no `__symbols__`, so an overlay cannot be
/// resolved against it.
test "base without symbols is rejected" {
  let src = "/dts-v1/; / { soc { uart0: serial@2000 { }; }; };"
  let out = try {
    let base = read_tree(encode_blob(parse_source(src)))
    let over_bytes = @fs.read_file_to_bytes(
      "internal/fixtures/overlay-uart.dtbo",
    )
    let over = parse_overlay(read_tree(over_bytes))
    let _ = apply_overlay(base, over)
    "applied"
  } catch {
    e => e.to_string()
  }
  inspect(
    out,
    content="base tree has no /__symbols__; build it with -@ to export its labels",
  )
}

///|
/// An overlay's properties are merged the way libfdt merges them: one the base
/// already has is replaced where it stands, and a new one is inserted ahead of
/// everything the base declared.
///
/// This is not a cosmetic ordering choice. `fdt_setprop` resizes in place on a
/// name it finds and otherwise calls `fdt_add_property_`, which splices the new
/// property tag at the position of the node's first property. Appending new
/// properties to the end instead produces the same set of properties in a
/// different order — a different blob, with a different struct block and a
/// different strings block.
test "overlay properties are inserted ahead of the base's" {
  let merged = apply_fixtures()
  let uart = node_at(merged, "/soc/serial@2000")
  // The base declared `compatible`, `reg`, `status`. `status` is replaced in
  // place; the two properties the overlay adds go in front of all three.
  let names : Array[String] = []
  for prop in uart.properties {
    names.push(prop.name)
  }
  // `interrupts` and `interrupt-parent` come from the overlay in that source
  // order, so the insert puts the last one it reads at the very front.
  inspect(names.length(), content="7")
  // The overlay's source order is status, clock-frequency, interrupt-parent,
  // interrupts. Each new one is inserted at the front, so the last one read
  // ends up first and the order comes out reversed ahead of the base.
  inspect(names[0], content="interrupts")
  inspect(names[1], content="interrupt-parent")
  inspect(names[2], content="clock-frequency")
  inspect(names[3], content="compatible")
}
