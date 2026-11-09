// Reference resolution tests.
//
// The numbering has to match dtc's, or a blob that parses fine points at the
// wrong node. The `nested` fixture already covers the common case through the
// byte comparison; these cases cover the ones it does not reach.

///|
/// Parses, resolves and encodes a source string.
fn encode_source(src : String) -> Bytes raise {
  encode_blob(resolve_references(parse_source(src)))
}

///|
/// Reads a `phandle` property from a node of a resolved tree.
fn phandle_of(file : SourceFile, path : Array[String]) -> UInt64 raise {
  let node = navigate(file.root, path, 0)
  for p in node.properties {
    if p.name == "phandle" {
      match p.value.parts[0] {
        Cells(cells) => return cells[0]
        _ => ()
      }
    }
  }
  raise Failure("no phandle at the requested path")
}

///|
/// Walks to a node by name.
fn navigate(
  node : SourceNode,
  path : Array[String],
  at : Int32,
) -> SourceNode raise {
  if at >= path.length() {
    return node
  }
  for c in node.children {
    if c.name == path[at] {
      return navigate(c, path, at + 1)
    }
  }
  raise Failure("no node named \{path[at]}")
}

///|
/// A node nobody refers to gets no phandle. dtc only assigns one where it is
/// needed, and adding one anyway would change the byte output.
test "unreferenced node gets no phandle" {
  let src =
    #|/dts-v1/;
    #|/ {
    #|  lonely { };
    #|};
  let file = resolve_references(parse_source(src))
  let node = navigate(file.root, ["lonely"], 0)
  let mut found = false
  for p in node.properties {
    if p.name == "phandle" {
      found = true
    }
  }
  inspect(found, content="false")
}

///|
/// Numbering starts at 1 and follows the order the source first refers to each
/// node, which is not the same as tree order. dtc numbers references as it
/// resolves them, so a board whose clock is referred to first gets 1 for the
/// clock even when another node appears earlier in the file.
test "phandle numbering follows reference order" {
  let src =
    #|/dts-v1/;
    #|/ {
    #|  a: alpha { };
    #|  b: beta { };
    #|  use {
    #|    x = <&b &a>;
    #|  };
    #|};
  let file = resolve_references(parse_source(src))
  // `beta` is referred to first in the value, so it is numbered first even
  // though `alpha` appears earlier in the file.
  inspect(phandle_of(file, ["beta"]), content="1")
  inspect(phandle_of(file, ["alpha"]), content="2")
}

///|
/// An explicit `phandle` keeps its number and is not reassigned.
test "explicit phandle is kept" {
  let src =
    #|/dts-v1/;
    #|/ {
    #|  a: alpha { phandle = <7>; };
    #|  use { x = <&a>; };
    #|};
  let file = resolve_references(parse_source(src))
  inspect(phandle_of(file, ["alpha"]), content="7")
}

///|
/// A label that is never bound is an error, reported by name.
test "unknown label" {
  let src =
    #|/dts-v1/;
    #|/ { use { x = <&missing>; }; };
  let out = try {
    let _ = resolve_references(parse_source(src))
    "resolved"
  } catch {
    e => e.to_string()
  }
  inspect(out, content="reference to unknown label 'missing'")
}

///|
/// A path reference needs no label and resolves directly.
test "path reference resolves" {
  let src =
    #|/dts-v1/;
    #|/ {
    #|  soc { bus { }; };
    #|  use { x = <&{/soc/bus}>; };
    #|};
  let file = resolve_references(parse_source(src))
  inspect(phandle_of(file, ["soc", "bus"]), content="1")
}

///|
/// Two nodes claiming the same label is rejected: the references in the file
/// would otherwise have no single meaning.
test "duplicate label" {
  let src =
    #|/dts-v1/;
    #|/ {
    #|  a: one { };
    #|  a: two { };
    #|};
  let out = try {
    let _ = resolve_references(parse_source(src))
    "resolved"
  } catch {
    e => e.to_string()
  }
  inspect(out, content="label 'a' used on both /one and /two")
}

///|
/// A resolved reference has to encode, and the resulting blob has to parse
/// back with the phandle visible.
test "resolved tree round-trips" {
  let src =
    #|/dts-v1/;
    #|/ {
    #|  intc: interrupt-controller { interrupt-controller; };
    #|  serial { interrupt-parent = <&intc>; };
    #|};
  let blob = encode_source(src)
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
  inspect(tree.warnings.length(), content="0")
  let serial = tree.root.children[1]
  inspect(serial.name, content="serial")
  let parent = serial.properties[0]
  inspect(parent.name, content="interrupt-parent")
  // One cell holding phandle 1.
  inspect(parent.value.length(), content="4")
  inspect(parent.value.at(3).to_int(), content="1")
}
