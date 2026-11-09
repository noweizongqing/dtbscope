// Parser tests.
//
// Sources here are small hand-written cases that each isolate one rule.
// `internal/fixtures/*.dts` are used as the realistic inputs; they are the same
// files dtc compiles, so a parse that succeeds on them is a parse that agrees
// with the format on real content.

///|
/// Parses and returns the root node, failing the test on an error.
fn root_of(source : String) -> SourceNode raise {
  let file = parse_source(source)
  file.root
}

///|
/// Finds a child node by name.
fn child_node(node : SourceNode, name : String) -> SourceNode raise {
  for c in node.children {
    if c.name == name {
      return c
    }
  }
  raise Failure("no child named \{name}")
}

///|
/// Finds a property by name.
fn find_prop(node : SourceNode, name : String) -> SourceProperty raise {
  for p in node.properties {
    if p.name == name {
      return p
    }
  }
  raise Failure("no property \{name}")
}

///|
/// Renders a value part as text so that assertions stay readable.
fn show_part(part : ValuePart) -> String {
  match part {
    Text(s) => "\"" + s + "\""
    Cells(cs) => "<" + join_nums(cs) + ">"
    Bytes(bs) => "[" + join_bytes(bs) + "]"
    Ref(l) => "&" + l
    PathRef(p) => "&{" + p + "}"
    Refs(inner) => {
      // Rendered as `<` and `>` around the pieces so that a mixed cell list
      // reads the same as a plain one in an assertion.
      let pieces : Array[String] = []
      for p in inner {
        pieces.push(show_part(p))
      }
      "<" + join_with(pieces, " ") + ">"
    }
    TypedCells(w, cs) => "/bits/ " + w.to_string() + " <" + join_nums(cs) + ">"
  }
}

///|
/// Joins numbers with spaces.
fn join_nums(values : Array[UInt64]) -> String {
  let buf = StringBuilder()
  let mut first = true
  for v in values {
    if !first {
      buf.write_string(" ")
    }
    first = false
    buf.write_string(v.to_string())
  }
  buf.to_string()
}

///|
/// Joins bytes as two hex digits each.
fn join_bytes(values : Array[Byte]) -> String {
  let digits = "0123456789abcdef"
  let buf = StringBuilder()
  let mut first = true
  for b in values {
    if !first {
      buf.write_string(" ")
    }
    first = false
    let n = b.to_int()
    buf.write_char(digits.get_char((n >> 4) & 0xF).unwrap())
    buf.write_char(digits.get_char(n & 0xF).unwrap())
  }
  buf.to_string()
}

///|
/// Renders a whole value as comma-separated parts.
fn show_value(v : Value) -> String {
  let parts : Array[String] = []
  for p in v.parts {
    parts.push(show_part(p))
  }
  join_with(parts, ", ")
}

///|
/// Joins strings with a separator.
fn join_with(values : Array[String], sep : String) -> String {
  let buf = StringBuilder()
  let mut first = true
  for v in values {
    if !first {
      buf.write_string(sep)
    }
    first = false
    buf.write_string(v)
  }
  buf.to_string()
}

///|
/// The smallest legal file: a version directive and an empty root node.
test "empty root node" {
  let root = root_of("/dts-v1/; / { };")
  inspect(root.name, content="")
  inspect(root.properties.length(), content="0")
  inspect(root.children.length(), content="0")
}

///|
/// Strings, cells and booleans on a root node.
test "property value forms" {
  let src =
    #|/dts-v1/;
    #|/ {
    #|  model = "test board";
    #|  #address-cells = <1>;
    #|  #size-cells = <2>;
    #|  interrupt-controller;
    #|  two = "a", "b";
    #|};
  let root = root_of(src)
  inspect(show_value(find_prop(root, "model").value), content="\"test board\"")
  inspect(show_value(find_prop(root, "#address-cells").value), content="<1>")
  inspect(show_value(find_prop(root, "#size-cells").value), content="<2>")
  inspect(show_value(find_prop(root, "interrupt-controller").value), content="")
  inspect(show_value(find_prop(root, "two").value), content="\"a\", \"b\"")
}

///|
/// A child node carrying a unit address and its own properties.
test "child node with unit address" {
  let src =
    #|/dts-v1/;
    #|/ {
    #|  soc {
    #|    serial@10000000 {
    #|      reg = <0x10000000 0x100>;
    #|      status = "okay";
    #|    };
    #|  };
    #|};
  let root = root_of(src)
  let soc = child_node(root, "soc")
  let serial = child_node(soc, "serial@10000000")
  inspect(show_value(find_prop(serial, "reg").value), content="<268435456 256>")
  inspect(show_value(find_prop(serial, "status").value), content="\"okay\"")
}

///|
/// A label before a node, then a reference to it from another node.
test "labels and references" {
  let src =
    #|/dts-v1/;
    #|/ {
    #|  intc: interrupt-controller@1000 {
    #|    interrupt-controller;
    #|    #interrupt-cells = <2>;
    #|  };
    #|  serial@2000 {
    #|    interrupt-parent = <&intc>;
    #|  };
    #|};
  let root = root_of(src)
  let intc = child_node(root, "interrupt-controller@1000")
  inspect(intc.labels.length(), content="1")
  inspect(intc.labels[0], content="intc")
  let serial = child_node(root, "serial@2000")
  inspect(
    show_value(find_prop(serial, "interrupt-parent").value),
    content="<<> &intc <>>",
  )
}

///|
/// A reference in the middle of a cell list, which is how `phandle`-taking
/// properties such as `clocks` are usually written.
test "reference between cells" {
  let src =
    #|/dts-v1/;
    #|/ {
    #|  clk: clock { };
    #|  dev {
    #|    clocks = <1 &clk 2>;
    #|  };
    #|};
  let root = root_of(src)
  let dev = child_node(root, "dev")
  // The reference splits the cell list, so the value comes back as one part
  // holding the pieces in order.
  let v = find_prop(dev, "clocks").value
  inspect(v.parts.length(), content="1")
  match v.parts[0] {
    Refs(inner) => inspect(inner.length(), content="3")
    _ => raise Failure("expected a Refs part")
  }
}

///|
/// A path reference, written `&{/path}` rather than through a label.
test "path reference" {
  let src =
    #|/dts-v1/;
    #|/ {
    #|  dev {
    #|    parent = <&{/soc/bus}>;
    #|  };
    #|  soc { bus { }; };
    #|};
  let root = root_of(src)
  let dev = child_node(root, "dev")
  inspect(
    show_value(find_prop(dev, "parent").value),
    content="<<> &{/soc/bus} <>>",
  )
}

///|
/// A byte string.
test "byte string" {
  let src =
    #|/dts-v1/;
    #|/ {
    #|  mac-address = [00 11 22 aa bb cc];
    #|};
  let root = root_of(src)
  inspect(
    show_value(find_prop(root, "mac-address").value),
    content="[00 11 22 aa bb cc]",
  )
}

///|
/// `/bits/ 8` narrows the cells to bytes.
test "bits directive" {
  let src =
    #|/dts-v1/;
    #|/ {
    #|  code = /bits/ 8 <0x12 0x34>;
    #|};
  let root = root_of(src)
  inspect(show_value(find_prop(root, "code").value), content="/bits/ 8 <18 52>")
}

///|
/// Comments and odd whitespace must not affect the result.
test "comments are skipped" {
  let src =
    #|// a line comment
    #|/dts-v1/;
    #|/* a block
    #|   comment spanning lines */
    #|/ {
    #|  model = "x"; // trailing
    #|};
  let root = root_of(src)
  inspect(show_value(find_prop(root, "model").value), content="\"x\"")
}

///|
/// The two realistic fixtures must parse. These are the same files dtc
/// compiles to the DTBs the binary reader is tested against.
test "fixtures parse" {
  for name in ["minimal.dts", "nested.dts"] {
    let src = @fs.read_file_to_string("internal/fixtures/" + name)
    let file = parse_source(src)
    inspect(file.root.children.length() > 0, content="true")
    inspect(file.is_plugin, content="false")
  }
}

///|
/// A file without the version directive is not a device tree source.
test "missing version directive" {
  let out = try {
    let _ = parse_source("/ { };")
    "accepted"
  } catch {
    e => e.to_string()
  }
  inspect(out, content="1:1: missing /dts-v1/; directive")
}

///|
/// A node body missing its closing semicolon is the most common hand-written
/// error, and the message names it rather than blaming the brace.
test "missing semicolon after node" {
  let out = try {
    let _ = parse_source("/dts-v1/; / { a { }; b { } };")
    "accepted"
  } catch {
    e => e.to_string()
  }
  inspect(out, content="1:28: expected ';' after '}', found '}'")
}

///|
/// A cell wider than 32 bits has no encoding, so it is rejected at parse time
/// rather than truncated.
test "cell too wide" {
  let out = try {
    let _ = parse_source("/dts-v1/; / { a = <0x100000000>; };")
    "accepted"
  } catch {
    e => e.to_string()
  }
  inspect(out, content="1:20: cell value 4294967296 does not fit in 32 bits")
}

///|
/// `/incbin/` reads an external file, which this version does not do.
test "incbin is unsupported" {
  let out = try {
    let _ = parse_source("/dts-v1/; / { a = /incbin/(\"x\"); };")
    "accepted"
  } catch {
    e => e.to_string()
  }
  inspect(out, content="1:19: unsupported: /incbin/")
}

///|
/// `/memreserve/` is recorded separately from the node tree.
test "memreserve" {
  let src =
    #|/dts-v1/;
    #|/memreserve/ 0x10000000 0x4000;
    #|/ { };
  let file = parse_source(src)
  inspect(file.memreserves.length(), content="1")
  inspect(file.memreserves[0].0, content="268435456")
  inspect(file.memreserves[0].1, content="16384")
}
