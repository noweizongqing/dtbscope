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
/// This is the reference form: it names a node from anywhere in the file and is
/// resolved against the finished tree, so the order of the directive and the
/// declaration does not matter. The bare-name form inside a body is a different
/// construct with different rules, covered by the tests below.
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

///|
/// `/delete-property/` inside a node body does nothing, which is what dtc does.
///
/// The directive means "remove this from the node I am patching". A body that
/// declares a property is not patching anything, so there is nothing to
/// remove. dtc accepts the syntax and ignores it; removing the property here
/// would make this compiler disagree with dtc on a source both accept.
test "delete-property in a body is a no-op" {
  let src =
    #|/dts-v1/;
    #|/ { n { a = <1>; b = <2>; /delete-property/ b; }; };
  let root = tree_of_source(src).root
  let n = root.children[0]
  inspect(n.properties.length(), content="2")
}

///|
/// In a patch it does remove the property, because there the node is being
/// modified rather than declared.
test "delete-property in a patch removes" {
  let src =
    #|/dts-v1/;
    #|/ { k: n { a = <1>; b = <2>; }; };
    #|&k { /delete-property/ b; };
  let root = tree_of_source(src).root
  let n = root.children[0]
  inspect(n.properties.length(), content="1")
  inspect(n.properties[0].name, content="a")
}

// ---------------------------------------------------------------------------
// `/delete-node/ <name>` inside a node body.
//
// This is dtc's `subnode: DT_DEL_NODE DT_PROPNODENAME ';'` production, and its
// rules are stricter and stranger than the reference form's. Everything below
// was checked against dtc 1.8.1 with the same source, including the cases where
// dtc's own behaviour looks like a bug.
// ---------------------------------------------------------------------------

///|
/// Parsing a source, expecting it to fail. Returns whether it did.
fn rejects(src : String) -> Bool {
  let outcome = Ok(build(src)) catch { _ => Err(()) }
  match outcome {
    Ok(_) => false
    Err(_) => true
  }
}

///|
/// Inside *one* body, a node followed by a marker of the same name is rejected
/// as a duplicate, so the only way to use the bare-name form in a single root
/// block is to name something that is not there.
///
/// This is the shape dtc's grammar allows and its duplicate check then rejects.
/// Both halves are one test because the point is the interaction: the grammar
/// accepts the construct, and the check turns it into an error anyway.
test "a node and a marker of the same name in one body is a duplicate" {
  let src =
    #|/dts-v1/;
    #|/ {
    #|  soc {
    #|    keep@1 { compatible = "k"; };
    #|    drop@2 { compatible = "d"; };
    #|    /delete-node/ drop@2;
    #|  };
    #|};
  inspect(rejects(src), content="true")
}

///|
/// A marker naming a sibling that has not been declared yet does nothing, and
/// the later declaration survives.
///
/// This is the ordering rule, and it is the one that reads as a bug: the same
/// two lines in the other order delete the node. It falls out of dtc applying
/// the marker during the merge rather than afterwards — when the marker is read
/// there is nothing yet to delete, and by the time the node arrives the marker
/// has already passed.
test "delete-node by name before the node does not remove it" {
  let src =
    #|/dts-v1/;
    #|/ {
    #|  soc {
    #|    /delete-node/ later@2;
    #|    later@2 { compatible = "l"; };
    #|  };
    #|};
  let root = tree_of_source(src).root
  for child in root.children {
    if child.name == "soc" {
      inspect(child.children.length(), content="1")
      inspect(child.children[0].name, content="later@2")
      return
    }
  }
  raise Failure("soc is missing")
}

///|
/// A marker for a name that was never declared is a silent no-op, not an error.
///
/// The reference form at top level errors on an unknown target; the bare-name
/// form does not. A source with a typo here compiles clean in dtc.
test "delete-node by name for an unknown sibling is a no-op" {
  let src =
    #|/dts-v1/;
    #|/ {
    #|  soc {
    #|    keep@1 { compatible = "k"; };
    #|    /delete-node/ typo@9;
    #|  };
    #|};
  let root = tree_of_source(src).root
  for child in root.children {
    if child.name == "soc" {
      inspect(child.children.length(), content="1")
      return
    }
  }
  raise Failure("soc is missing")
}

///|
/// Across root blocks the merge reaches a node an earlier block declared, so a
/// marker in a second `/ { soc { ... } };` does delete.
///
/// This is how a board file overrides a dtsi: the include brings in a root
/// block, the board file adds another, and the two are merged.
test "delete-node by name reaches across root blocks" {
  let src =
    #|/dts-v1/;
    #|/ { soc { a@1 { compatible = "a"; }; b@2 { compatible = "b"; }; }; };
    #|/ { soc { /delete-node/ b@2; }; };
  let root = tree_of_source(src).root
  for child in root.children {
    if child.name == "soc" {
      inspect(child.children.length(), content="1")
      inspect(child.children[0].name, content="a@1")
      return
    }
  }
  raise Failure("soc is missing")
}

///|
/// Deleting a node and then declaring it again keeps the properties it had
/// before the deletion, merged with the new ones.
///
/// dtc's `delete_node` sets a flag instead of unlinking, so the re-declaration
/// merges into the same struct and `merge_nodes` clears the flag. The old
/// properties therefore survive. A compiler that truly removed the node here
/// would produce a tree missing `extra`.
test "re-declaring a deleted node keeps its earlier properties" {
  let src =
    #|/dts-v1/;
    #|/ { a@1 { compatible = "a"; extra = "keep"; }; };
    #|/ {
    #|  a@1 {
    #|    /delete-node/ a@1;
    #|  };
    #|  a@1 { compatible = "b"; };
    #|};
  let root = tree_of_source(src).root
  inspect(root.children.length(), content="1")
  let node = root.children[0]
  inspect(node.name, content="a@1")
  // Both properties, in the order dtc emits: the overridden one in place, the
  // surviving one after it.
  inspect(node.properties.length(), content="2")
  inspect(node.properties[0].name, content="compatible")
  inspect(node.properties[1].name, content="extra")
}

///|
/// Deleting the same node twice by reference is an error, not a no-op.
///
/// dtc's `get_node_by_ref` skips deleted nodes, so the second marker cannot
/// find anything and reports "Label or path ... not found". This is the one
/// place the reference form is *stricter* than the bare-name form, which stays
/// silent when it finds nothing.
test "deleting the same node twice by reference is rejected" {
  let src =
    #|/dts-v1/;
    #|/ { soc { a@1 { compatible = "a"; }; }; };
    #|/delete-node/ &{/soc/a@1};
    #|/delete-node/ &{/soc/a@1};
  inspect(rejects(src), content="true")
}

///|
/// A property written after a subnode in the same body is rejected, which is
/// dtc's `Properties must precede subnodes`.
///
/// The rule constrains one body, not the file: a property in a second root
/// block may come after the first block's subnodes, and that is covered by the
/// merge tests rather than here.
test "a property after a subnode in one body is rejected" {
  let src =
    #|/dts-v1/;
    #|/ {
    #|  soc { a@1 { compatible = "a"; }; };
    #|  late = "p";
    #|};
  inspect(rejects(src), content="true")
}

///|
/// A deleted node is absent from the encoded blob, not merely flagged in it.
test "a deleted node does not reach the blob" {
  let src =
    #|/dts-v1/;
    #|/ { soc { a@1 { compatible = "a"; }; b@2 { compatible = "b"; }; }; };
    #|/ { soc { /delete-node/ b@2; }; };
  let tree = tree_of_source(src)
  for child in tree.root.children {
    if child.name == "soc" {
      inspect(child.children.length(), content="1")
      return
    }
  }
  raise Failure("soc is missing")
}

///|
/// A reference deletion applies at the point it is read, so a later root block
/// that re-declares the node revives it — but only with what the second
/// declaration wrote.
///
/// Two separate things are being pinned, and the second is the one that is easy
/// to get wrong in the generous direction:
///
/// * The ordering. Collecting deletions and running them after the file would
///   delete the revival and leave nothing behind.
/// * The contents. dtc's `delete_node` marks every property of the target
///   deleted as well, so `extra` does not come back. A compiler that only
///   flagged the node would leave both properties and produce a longer
///   property list than dtc.
test "a reference deletion can be undone by a later root block" {
  let src =
    #|/dts-v1/;
    #|/ { soc { a@1 { compatible = "a"; extra = "kept"; }; }; };
    #|/delete-node/ &{/soc/a@1};
    #|/ { soc { a@1 { compatible = "b"; }; }; };
  let root = tree_of_source(src).root
  for child in root.children {
    if child.name != "soc" {
      continue
    }
    inspect(child.children.length(), content="1")
    let revived = child.children[0]
    inspect(revived.name, content="a@1")
    inspect(revived.properties.length(), content="1")
    inspect(revived.properties[0].name, content="compatible")
    return
  }
  raise Failure("soc is missing")
}

///|
/// A marker nested inside a named body clears that wrapper's properties, not the
/// target's, so the target's properties survive its revival.
///
/// This is the mirror of the reference-deletion case above and produces the
/// opposite result, which is why both are tested. `delete_node` acts on the node
/// the marker lands on — here the `x@1 { }` wrapper a later root block merges in
/// — and that wrapper has no properties of its own. The node it deletes is the
/// earlier `x@1`, whose properties were never on the wrapper to begin with.
test "a marker inside a named body leaves the target's properties alive" {
  let src =
    #|/dts-v1/;
    #|/ { x@1 { compatible = "a"; extra = "keep"; }; };
    #|/ { x@1 { /delete-node/ x@1; }; };
    #|/ { x@1 { compatible = "b"; }; };
  let root = tree_of_source(src).root
  inspect(root.children.length(), content="1")
  let node = root.children[0]
  inspect(node.name, content="x@1")
  inspect(node.properties.length(), content="2")
  inspect(node.properties[0].name, content="compatible")
  inspect(node.properties[1].name, content="extra")
}

///|
/// A marker nested inside a named body lets the wrapper's own properties through
/// as well, not only the target's.
///
/// The previous test shows the target keeps its properties. This one shows the
/// wrapper's survive too, which rules out "the wrapper is stripped and only
/// happens to look empty": a `wrap = "w";` next to the marker comes out the
/// other side. dtc 1.8.1 emits all three properties for this source.
test "a marker inside a named body keeps the wrapper's properties" {
  let src =
    #|/dts-v1/;
    #|/ { x@1 { compatible = "a"; extra = "keep"; }; };
    #|/ { x@1 { wrap = "w"; /delete-node/ x@1; }; };
    #|/ { x@1 { compatible = "b"; }; };
  let root = tree_of_source(src).root
  inspect(root.children.length(), content="1")
  let node = root.children[0]
  inspect(node.properties.length(), content="3")
  inspect(node.properties[0].name, content="compatible")
}

///|
/// A marker acting as a sibling of its target strips the target's properties, so
/// the revival carries only what the new declaration wrote.
///
/// This is the third shape and it agrees with the reference form rather than
/// with the nested one: the marker is merged into the parent, finds the target
/// among the parent's children, and deletes its contents. The difference from
/// `x@1 { /delete-node/ x@1; }` is that the marker is not inside the node it
/// names, so it actually reaches it.
test "a sibling marker strips the target's properties" {
  let src =
    #|/dts-v1/;
    #|/ { x@1 { compatible = "a"; extra = "keep"; }; };
    #|/ { /delete-node/ x@1; };
    #|/ { x@1 { compatible = "b"; }; };
  let root = tree_of_source(src).root
  inspect(root.children.length(), content="1")
  let node = root.children[0]
  inspect(node.name, content="x@1")
  inspect(node.properties.length(), content="1")
  inspect(node.properties[0].name, content="compatible")
}

///|
/// The same shape one level down, where the marker and its target are children
/// of a named node rather than of the root.
///
/// Worth its own test because the root and a nested node reach the merge by
/// different paths: the root's children come from the top-level scan, a named
/// node's from the recursive merge. Both must reach the same rule.
test "a nested sibling marker strips the target's properties" {
  let src =
    #|/dts-v1/;
    #|/ { soc { x@1 { compatible = "a"; extra = "keep"; }; }; };
    #|/ { soc { /delete-node/ x@1; }; };
    #|/ { soc { x@1 { compatible = "b"; }; }; };
  let root = tree_of_source(src).root
  for child in root.children {
    if child.name != "soc" {
      continue
    }
    inspect(child.children.length(), content="1")
    inspect(child.children[0].properties.length(), content="1")
    return
  }
  raise Failure("soc is missing")
}

///|
/// A reference deletion whose path does not resolve is an error, not a silent
/// no-op.
///
/// `&{/b}` inside `/ { a { b { }; }; }` is missing the `a` segment. dtc reports
/// "Label or path /b not found"; ignoring it would delete nothing and produce a
/// tree that is quietly wrong.
test "a path deletion that names nothing is rejected" {
  let src =
    #|/dts-v1/;
    #|/ { a { b { }; }; };
    #|/delete-node/ &{/b};
  inspect(rejects(src), content="true")
}

///|
/// A patch written before a deletion sees the node the deletion later removes.
///
/// dtc applies both in source order, so the patch resolves against a tree that
/// still has the node. Collecting patches and running them after all deletions
/// reports an unknown label instead, which is what this pins.
test "a patch before a deletion resolves against the undeleted tree" {
  let src =
    #|/dts-v1/;
    #|/ { lab: a@1 { }; };
    #|&lab { patched = <1>; };
    #|/delete-node/ &{/a@1};
  let root = tree_of_source(src).root
  // The node is deleted, so the tree is empty; what matters is that compiling
  // did not fail on the patch.
  inspect(root.children.length(), content="0")
}

///|
/// A patch written after the same deletion cannot resolve, because the label
/// went with the node.
test "a patch after a deletion cannot resolve its label" {
  let src =
    #|/dts-v1/;
    #|/ { lab: a@1 { }; };
    #|/delete-node/ &{/a@1};
    #|&lab { patched = <1>; };
  inspect(rejects(src), content="true")
}

///|
/// A plugin with no fragments is rejected.
///
/// dtc's grammar is `versioninfo plugindecl memreserves devicetree`: the tree
/// is required even for a plugin, and a file that stops after `/plugin/;` is a
/// syntax error. Accepting it would compile a source dtc refuses.
test "an empty plugin is rejected" {
  let src =
    #|/dts-v1/;
    #|/plugin/;
  inspect(rejects(src), content="true")
}

///|
/// A bare `&label` outside `<...>` becomes the target's path as a string; the
/// same reference inside `<...>` becomes its phandle.
///
/// The two forms look almost identical and produce completely different values,
/// so a compiler that treats them alike emits a blob with a number where every
/// consumer expects a path. dtc's grammar distinguishes them as REF_PATH and
/// REF_PHANDLE, and only the second one takes part in phandle numbering — so a
/// bare reference must not shift the numbers the phandles get.
test "a bare reference becomes a path and an angled one becomes a phandle" {
  let src =
    #|/dts-v1/;
    #|/ { n1@200 { }; };
    #|/ {
    #|  a = &{/n1@200};
    #|  b = <&{/n1@200}>;
    #|};
  let tree = tree_of_source(src)
  let root = tree.root
  let mut path_value = ""
  let mut cell_value = 0UL
  for prop in root.properties {
    let bounds = Bounds::of_bytes(prop.value)
    if prop.name == "a" {
      let bytes = prop.value
      let as_text = StringBuilder()
      for i in 0..<(bytes.length() - 1) {
        as_text.write_char(bytes.at(i).to_char())
      }
      path_value = as_text.to_string()
    } else if prop.name == "b" {
      let (v, _) = bounds.read_u32(Cursor::big(0L))
      cell_value = v.to_uint64()
    }
  }
  inspect(path_value, content="/n1@200")
  // A phandle was assigned, so the cell is not zero.
  inspect(cell_value > 0UL, content="true")
}

///|
/// A bare reference keeps its target alive against `/omit-if-no-ref/`.
///
/// dtc calls `reference_node` on the target of a path reference for this
/// reason. Without it, a node that is only ever named in `/aliases` would be
/// dropped, and a board file that names its UART solely through an alias would
/// lose the UART. The control case is the same node with no reference at all,
/// which must disappear; both halves are checked so that "keeps everything"
/// cannot pass.
test "a bare reference keeps an omit-if-no-ref node" {
  let kept =
    #|/dts-v1/;
    #|/ {
    #|  /omit-if-no-ref/ u: uart@1000 { reg = <0x1000 0x100>; };
    #|};
    #|/ { aliases { console = &u; }; };
  let root = tree_of_source(kept).root
  let mut saw_uart = false
  for child in root.children {
    if child.name == "uart@1000" {
      saw_uart = true
    }
  }
  inspect(saw_uart, content="true")

  let dropped =
    #|/dts-v1/;
    #|/ {
    #|  /omit-if-no-ref/ u: uart@1000 { reg = <0x1000 0x100>; };
    #|};
  inspect(tree_of_source(dropped).root.children.length(), content="0")
}
