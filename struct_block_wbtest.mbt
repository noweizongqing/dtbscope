// Struct block tests.
//
// The expected shapes are transcribed from `dtc -I dtb -O dts` on the same
// fixture, so a disagreement here means our walk lost or reordered something
// that dtc keeps.

///|
/// Reads a fixture and returns the tree dtc would describe.
fn tree_of(name : String) -> Tree raise {
  let bytes = @fs.read_file_to_bytes("internal/fixtures/" + name)
  let header = parse_header(bytes)
  let struct_bounds = Bounds::of_range(
    bytes,
    header.off_dt_struct,
    header.off_dt_struct + header.size_dt_struct,
  )
  let strings_bounds = Bounds::of_range(
    bytes,
    header.off_dt_strings,
    header.off_dt_strings + header.size_dt_strings,
  )
  parse_struct(struct_bounds, strings_bounds)
}

///|
/// Finds a child by name, failing the test rather than returning an option so
/// that the assertion below stays readable.
fn child(node : Node, name : String) -> Node raise {
  for c in node.children {
    if c.name == name {
      return c
    }
  }
  raise Failure("no child named \{name} under /\{node.name}")
}

///|
/// Finds a property by name.
fn prop(node : Node, name : String) -> Property raise {
  for p in node.properties {
    if p.name == name {
      return p
    }
  }
  raise Failure("no property \{name} on /\{node.name}")
}

///|
/// Decodes a property value as big-endian 32-bit cells.
fn cells(p : Property) -> Array[Int64] raise {
  let b = Bounds::of_bytes(p.value)
  let out : Array[Int64] = []
  let mut cur = Cursor::big(0L)
  while cur.pos < b.length() {
    let (v, next) = b.read_u32(cur)
    out.push(v.to_int64())
    cur = next
  }
  out
}

///|
/// Joins cells with commas so that an assertion can name the whole list
/// without depending on the debug formatting of arrays.
fn join_cells(values : Array[Int64]) -> String {
  let buf = StringBuilder()
  let mut first = true
  for v in values {
    if !first {
      buf.write_string(",")
    }
    first = false
    buf.write_string(v.to_string())
  }
  buf.to_string()
}

///|
/// Decodes a property value as a UTF-8 string with its trailing NUL removed,
/// which is how a string property is stored.
fn text(p : Property) -> String raise {
  let raw = Bounds::of_bytes(p.value)
  let (s, _) = raw.cstr(0L, raw.length())
  s
}

///|
/// The whole tree of the minimal fixture, node by node.
test "minimal fixture: node tree" {
  let tree = tree_of("minimal.dtb")
  let root = tree.root
  inspect(root.name, content="")
  inspect(root.properties.length(), content="4")
  inspect(root.children.length(), content="2")
  inspect(root.children[0].name, content="chosen")
  inspect(root.children[1].name, content="memory@80000000")
  inspect(tree.warnings.length(), content="0")
}

///|
/// Property values, checked against what `dtc -I dtb -O dts` prints for the
/// same file.
test "minimal fixture: property values" {
  let root = tree_of("minimal.dtb").root
  inspect(text(prop(root, "compatible")), content="dtbscope,minimal")
  inspect(text(prop(root, "model")), content="dtbscope minimal board")
  inspect(join_cells(cells(prop(root, "#address-cells"))), content="1")
  inspect(join_cells(cells(prop(root, "#size-cells"))), content="1")
  let mem = child(root, "memory@80000000")
  inspect(text(prop(mem, "device_type")), content="memory")
  inspect(join_cells(cells(prop(mem, "reg"))), content="2147483648,268435456")
}

///|
/// A property that appears outside any node has nowhere to live. dtc rejects
/// such a blob and so do we, rather than inventing a parent.
test "property before any node is rejected" {
  let blob = Buffer::Buffer()
  blob.write_int_be(0x3)
  blob.write_int_be(0)
  blob.write_int_be(0)
  let bounds = Bounds::of_bytes(blob.to_bytes())
  let out = try {
    let _ = parse_struct(bounds, bounds)
    "accepted"
  } catch {
    e => e.to_string()
  }
  inspect(out, content="PROP is inconsistent: appears before any BEGIN_NODE")
}

///|
/// An END_NODE with no open node is a damaged blob, not an empty tree.
test "unbalanced end node is rejected" {
  let blob = Buffer::Buffer()
  blob.write_int_be(0x2)
  let bounds = Bounds::of_bytes(blob.to_bytes())
  let out = try {
    let _ = parse_struct(bounds, bounds)
    "accepted"
  } catch {
    e => e.to_string()
  }
  inspect(
    out,
    content="END_NODE is inconsistent: closes a node that was never opened",
  )
}

///|
/// Reaching the end of the block without an END token is tolerated with a
/// warning: the tree above it is still complete, and refusing the whole blob
/// would hide it.
test "missing end token warns instead of failing" {
  let blob = Buffer::Buffer()
  blob.write_int_be(0x1)
  blob.write_int_be(0x0)
  let bounds = Bounds::of_bytes(blob.to_bytes())
  let tree = parse_struct(bounds, bounds)
  inspect(tree.warnings.length(), content="1")
  inspect(
    tree.warnings[0].to_string(),
    content="struct block ended at 8 without an END token",
  )
  // The single node the blob did open becomes the root.
  inspect(tree.root.name, content="")
  inspect(tree.root.children.length(), content="0")
}

///|
/// The nesting limit has to trigger on a hostile blob rather than letting the
/// explicit stack grow without bound.
test "depth limit" {
  let blob = Buffer::Buffer()
  // 100 empty nodes, no closes: deeper than MAX_DEPTH.
  for i in 0..<100 {
    blob.write_int_be(0x1)
    blob.write_int_be(0x0)
    ignore(i)
  }
  let bounds = Bounds::of_bytes(blob.to_bytes())
  let out = try {
    let _ = parse_struct(bounds, bounds)
    "accepted"
  } catch {
    e => e.to_string()
  }
  inspect(out, content="node nesting exceeds the limit of 64")
}

///|
/// Flattens a tree into `path` and `property=value` lines so a whole fixture
/// can be compared in one assertion.
fn outline(tree : Tree) -> String {
  let buf = StringBuilder()
  walk_outline(tree.root, "/", buf)
  buf.to_string()
}

///|
/// Depth here is bounded by MAX_DEPTH, which is far below anything that would
/// strain the test harness stack.
fn walk_outline(node : Node, path : String, buf : StringBuilder) -> Unit {
  buf.write_string(path + "\n")
  for p in node.properties {
    buf.write_string("  " + p.name + "=" + describe_value(p) + "\n")
  }
  for c in node.children {
    walk_outline(c, path + c.name + "/", buf)
  }
}

///|
/// Renders a value as a quoted string when it is NUL-terminated printable
/// text, otherwise as a cell list. This exists only to make the assertion
/// below readable.
fn describe_value(p : Property) -> String {
  let n = p.value.length()
  let mut printable = n > 0 && p.value.at(n - 1).to_int() == 0
  if printable {
    for i in 0..<(n - 1) {
      let b = p.value.at(i).to_int()
      if b < 0x20 || b > 0x7E {
        printable = false
      }
    }
  }
  if printable {
    let raw = Bounds::of_bytes(p.value)
    try {
      let (s, _) = raw.cstr(0L, raw.length())
      "\"" + s + "\""
    } catch {
      _ => "<unreadable>"
    }
  } else {
    let b = Bounds::of_bytes(p.value)
    let out : Array[String] = []
    let mut cur = Cursor::big(0L)
    while cur.pos + 4L <= b.length() {
      let step = try {
        let (v, next) = b.read_u32(cur)
        out.push(v.to_int64().to_string())
        Some(next)
      } catch {
        _ => None
      }
      match step {
        Some(next) => cur = next
        None => break
      }
    }
    "<" + join_spaced(out) + ">"
  }
}

///|
/// Joins formatted cells with single spaces, matching how dtc prints them.
fn join_spaced(values : Array[String]) -> String {
  let buf = StringBuilder()
  let mut first = true
  for v in values {
    if !first {
      buf.write_string(" ")
    }
    first = false
    buf.write_string(v)
  }
  buf.to_string()
}

///|
/// The full outline of the nested fixture. Every line was read off
/// `dtc -I dtb -O dts nested.dtb` on the same bytes.
test "nested fixture: whole tree" {
  let tree = tree_of("nested.dtb")
  inspect(tree.warnings.length(), content="0")
  let want =
    #|/
    #|  compatible="dtbscope,nested"
    #|  #address-cells=<2>
    #|  #size-cells=<2>
    #|  interrupt-parent=<1>
    #|/aliases/
    #|  serial0="/soc/serial@10000000"
    #|/cpus/
    #|  #address-cells=<1>
    #|  #size-cells=<0>
    #|/cpus/cpu@0/
    #|  device_type="cpu"
    #|  compatible="arm,cortex-a72"
    #|  reg=<0>
    #|  enable-method="psci"
    #|/cpus/cpu@1/
    #|  device_type="cpu"
    #|  compatible="arm,cortex-a72"
    #|  reg=<1>
    #|  enable-method="psci"
    #|/soc/
    #|  compatible="simple-bus"
    #|  #address-cells=<2>
    #|  #size-cells=<2>
    #|  ranges=<>
    #|/soc/interrupt-controller@fff01000/
    #|  compatible="arm,gic-400"
    #|  #interrupt-cells=<3>
    #|  interrupt-controller=<>
    #|  reg=<0 4293922816 0 4096 0 4293926912 0 8192>
    #|  phandle=<1>
    #|/soc/serial@10000000/
    #|  compatible="ns16550a"
    #|  reg=<0 268435456 0 256>
    #|  interrupts=<0 1 4>
    #|  clock-frequency=<1843200>
    #|/chosen/
    #|  stdout-path="/soc/serial@10000000"
    #|  bootargs="console=ttyAMA0,115200 root=/dev/nfs"
    #|
  inspect(outline(tree), content=want)
}
