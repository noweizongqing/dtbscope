// Syntax-level language features: expressions, the deletion and omission
// directives, and `/include/`.
//
// These are part of the DTS grammar rather than of any preprocessor — dtc
// implements all of them itself — so a compiler that leaves them out cannot
// take a kernel board file. The expected values below were read off dtc 1.8.1
// for the same source.

///|
/// Parses, resolves and encodes a source string.
fn build(src : String) -> Bytes raise {
  encode_blob(resolve_references(parse_source(src)))
}

///|
/// Encodes and decodes a source, returning its tree.
fn tree_of_source(src : String) -> Tree raise {
  parse_tree(build(src))
}

///|
/// Reads the first cell of a property.
fn cell_of(node : Node, name : String) -> UInt64 raise {
  for p in node.properties {
    if p.name == name {
      let bounds = Bounds::of_bytes(p.value)
      let (v, _) = bounds.read_u32(Cursor::big(0L))
      return v.to_uint64()
    }
  }
  raise Failure("no property \{name}")
}

///|
/// The expression forms from the specification, each evaluated the way dtc
/// evaluates it.
///
/// One test rather than sixteen because the failure mode is the same for all
/// of them — the precedence table is wrong — and a single case that fails says
/// which one, while sixteen passing cases say the table is right.
test "expressions follow C precedence" {
  let src =
    #|/dts-v1/;
    #|/ {
    #|  a = <(1 + 2)>;
    #|  b = <(4 * 5)>;
    #|  c = <(1 << 8)>;
    #|  d = <(0x1000 | 0xf)>;
    #|  e = <(1 + 2 * 3)>;
    #|  f = <((1 + 2) * 3)>;
    #|  g = <(7 / 2)>;
    #|  h = <(7 % 2)>;
    #|  i = <(0xff & 0x0f)>;
    #|  j = <(1 ^ 3)>;
    #|  k = <(1 < 2)>;
    #|  l = <(2 >= 3)>;
    #|  m = <(1 ? 10 : 20)>;
    #|  n = <(~5)>;
    #|  o = <(!0)>;
    #|  p = <(-1)>;
    #|};
  let root = tree_of_source(src).root
  // Values are read as hex from dtc's dump, converted here.
  let expected = [
    ("a", 3UL),
    ("b", 20UL),
    ("c", 256UL),
    ("d", 0x100fUL),
    ("e", 7UL),
    ("f", 9UL),
    ("g", 3UL),
    ("h", 1UL),
    ("i", 0xfUL),
    ("j", 2UL),
    ("k", 1UL),
    ("l", 0UL),
    ("m", 10UL),
    ("n", 0xfffffffaUL),
    ("o", 1UL),
    ("p", 0xffffffffUL),
  ]
  for (name, want) in expected {
    inspect(cell_of(root, name), content="\{want}")
  }
}

///|
/// A shift by 64 is refused rather than wrapping.
///
/// C leaves it undefined and dtc inherits that; a count of 64 in a source file
/// is a mistake, and producing some arbitrary number would hide it.
test "expression: shift out of range" {
  let out = try {
    let _ = parse_source("/dts-v1/; / { a = <(1 << 64)>; };")
    "accepted"
  } catch {
    e => e.to_string()
  }
  inspect(out.contains("shift by 64"), content="true")
}

///|
/// Division by zero is refused.
test "expression: division by zero" {
  let out = try {
    let _ = parse_source("/dts-v1/; / { a = <(1 / 0)>; };")
    "accepted"
  } catch {
    e => e.to_string()
  }
  inspect(out.contains("division by zero"), content="true")
}

///|
/// `/delete-property/` removes a property a patch did not want to inherit.
test "delete-property removes the property" {
  let src =
    #|/dts-v1/;
    #|/ { k: n { x = <1>; y = <2>; }; };
    #|&k { /delete-property/ y; };
  let root = tree_of_source(src).root
  let n = root.children[0]
  inspect(n.properties.length(), content="1")
  inspect(n.properties[0].name, content="x")
}

///|
/// `/delete-node/ &label;` at the top level removes a node.
///
/// This is the only placement dtc accepts: inside a body the directive is
/// rejected as a misplaced property, and a bare name is rejected as a
/// duplicate node name, so a reference at top level is the whole form.
test "delete-node removes the node" {
  let src =
    #|/dts-v1/;
    #|/ { d: dropme { a = <1>; }; keep { b = <2>; }; };
    #|/delete-node/ &d;
  let root = tree_of_source(src).root
  inspect(root.children.length(), content="1")
  inspect(root.children[0].name, content="keep")
}

///|
/// `/delete-node/ &{/path}` names a node nested below the top level.
test "delete-node by path" {
  let src =
    #|/dts-v1/;
    #|/ { keep { a = <1>; }; soc { bus { }; }; };
    #|/delete-node/ &{/soc/bus};
  let root = tree_of_source(src).root
  for child in root.children {
    if child.name == "soc" {
      inspect(child.children.length(), content="0")
      return
    }
  }
  raise Failure("soc is missing")
}

///|
/// `/omit-if-no-ref/` drops a node nothing refers to and keeps one that is
/// referred to.
///
/// Both halves matter: dropping everything would pass a test that only checked
/// the unreferenced node, and keeping everything would pass one that only
/// checked the referenced one.
test "omit-if-no-ref drops only unreferenced nodes" {
  let src =
    #|/dts-v1/;
    #|/ {
    #|  /omit-if-no-ref/ unref { a = <1>; };
    #|  /omit-if-no-ref/ r: used { a = <2>; };
    #|  consumer { x = <&r>; };
    #|};
  let root = tree_of_source(src).root
  let names : Array[String] = []
  for child in root.children {
    names.push(child.name)
  }
  inspect(names.length(), content="2")
  inspect(names[0], content="used")
  inspect(names[1], content="consumer")
}

///|
/// A patch adds to a node without replacing what the node already had.
test "a top-level patch merges" {
  let src =
    #|/dts-v1/;
    #|/ { k: n { a = <1>; }; };
    #|&k { b = <2>; };
  let root = tree_of_source(src).root
  let n = root.children[0]
  inspect(n.properties.length(), content="2")
  inspect(n.properties[0].name, content="a")
  inspect(n.properties[1].name, content="b")
}

///|
/// Two `/ { };` blocks at the top level are one node.
///
/// An `/include/` that brings in a file with its own root block produces this
/// shape, so refusing the second block would make a legal include fail.
test "two root blocks merge" {
  let src =
    #|/dts-v1/;
    #|/ { a = <1>; };
    #|/ { b = <2>; };
  let root = tree_of_source(src).root
  inspect(root.properties.length(), content="2")
}

///|
/// `/include/` splices a file in, resolving the path against the including
/// file rather than the working directory.
test "include expands a file" {
  let files : Map[String, String] = Map([
    ("/board.dtsi", "/ { model = \"included\"; };"),
  ])
  let read = (path : String) => {
    match files.get(path) {
      Some(body) => Ok(body)
      None => Err("not found")
    }
  }
  let text = expand_includes("/include/ \"board.dtsi\"\n", "/main.dts", read)
  inspect(text.contains("included"), content="true")
}

///|
/// An include that names itself is a cycle, not an infinite loop.
test "include cycle is refused" {
  let read = (path : String) => {
    ignore(path)
    Ok("/include/ \"loop.dtsi\"\n")
  }
  let out = try {
    let _ = expand_includes("/include/ \"loop.dtsi\"\n", "/loop.dtsi", read)
    "expanded"
  } catch {
    e => e.to_string()
  }
  inspect(out.contains("include cycle"), content="true")
}

///|
/// A missing include names the file it could not find.
test "include names the missing file" {
  let read = (path : String) => {
    ignore(path)
    Err("not found")
  }
  let out = try {
    let _ = expand_includes("/include/ \"absent.dtsi\"\n", "/a/b.dts", read)
    "expanded"
  } catch {
    e => e.to_string()
  }
  inspect(out.contains("/a/absent.dtsi"), content="true")
}
