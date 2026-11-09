// Reference resolution and phandle assignment.
//
// A source file names nodes two ways: a label (`intc: interrupt-controller {`)
// and a path (`&{/soc/bus}`). Both are turned into a 32-bit number that a
// property can hold, and that number is what the binary form stores.
//
// dtc assigns phandles in the order it walks the tree, numbered from 1. Two
// separate cases have to be handled: a node dtc gives a phandle because
// something refers to it, and a node that already carries an explicit
// `phandle = <N>` property, whose value must be kept rather than reassigned.
// Getting this wrong produces a blob where the references point at the wrong
// node, which still parses and still boots on the wrong hardware.

///|
/// Every way resolution can fail.
///
/// These are separate from `ParseError` because a source file can be perfectly
/// well-formed and still refer to a node that does not exist. That is a
/// linking problem, not a syntax one, and dtc reports it the same way.
pub(all) suberror ResolveError {
  /// A label was referenced but never bound.
  UnknownLabel(label~ : String)
  /// A path reference names a node that is not in the tree.
  UnknownPath(path~ : String)
  /// Two nodes claimed the same label.
  DuplicateLabel(label~ : String, first~ : String, second~ : String)
  /// Two nodes claimed the same explicit phandle number.
  DuplicatePhandle(value~ : UInt32, first~ : String, second~ : String)
  /// A phandle value of 0 or of the two reserved values is not legal.
  BadPhandle(value~ : UInt32, node~ : String)
}

///|
/// Renders a resolution error.
pub impl Show for ResolveError with fn output(self, logger) {
  let text = match self {
    UnknownLabel(label~) => "reference to unknown label '\{label}'"
    UnknownPath(path~) => "reference to unknown path '\{path}'"
    DuplicateLabel(label~, first~, second~) =>
      "label '\{label}' used on both \{first} and \{second}"
    DuplicatePhandle(value~, first~, second~) =>
      "phandle \{value} used on both \{first} and \{second}"
    BadPhandle(value~, node~) => "bad phandle value \{value} on \{node}"
  }
  logger.write_string(text)
}

///|
/// Exposes the resolution error message as a plain method.
pub extend ResolveError with Show::{to_string, output}

///|
/// Where every label points, and where every explicit phandle already is.
///
/// Built in one pass over the tree before any reference is rewritten, so that
/// a forward reference — a node referred to by a node that appears before it —
/// works the same as a backward one. dtc allows both; a streaming resolver
/// would not.
pub(all) struct LabelTable {
  /// Label name to the path of the node it names.
  labels : Map[String, String]
  /// Path to the number an explicit `phandle` property already gave it.
  explicit : Map[String, UInt32]
}

///|
/// The root node's path, which is how a label table keys nodes.
const ROOT_PATH : String = "/"

///|
/// Walks the tree recording labels and explicit phandles.
///
/// A label is bound to the path of the node that carries it. Two nodes with
/// the same label is an error rather than a last-one-wins, because the
/// references in the file then have no single meaning.
fn collect_labels(
  node : SourceNode,
  path : String,
  table : LabelTable,
) -> Unit raise ResolveError {
  for label in node.labels {
    match table.labels.get(label) {
      Some(existing) =>
        if existing != path {
          raise DuplicateLabel(label~, first=existing, second=path)
        }
      None => table.labels.set(label, path)
    }
  }
  match explicit_phandle(node) {
    Some(value) => {
      if value == 0U || value == 0xFFFF_FFFFU {
        raise BadPhandle(value~, node=path)
      }
      match table.explicit.get(path) {
        Some(_) => ()
        None => table.explicit.set(path, value)
      }
    }
    None => ()
  }
  for child in node.children {
    collect_labels(child, join_path(path, child.name), table)
  }
}

///|
/// Reads an explicit `phandle = <N>` from a node, if it has one.
///
/// Only a single-cell value counts: a multi-part phandle would not be a number
/// and dtc rejects it, and silently taking the first cell would hide that.
fn explicit_phandle(node : SourceNode) -> UInt32? {
  for prop in node.properties {
    if prop.name == "phandle" || prop.name == "linux,phandle" {
      if prop.value.parts.length() == 1 {
        match prop.value.parts[0] {
          Cells(cells) =>
            if cells.length() == 1 && cells[0] <= 0xFFFF_FFFFUL {
              return Some(cells[0].to_int().reinterpret_as_uint())
            }
          _ => ()
        }
      }
    }
  }
  None
}

///|
/// Appends a child name to a path, matching how a node path is spelled.
fn join_path(parent : String, name : String) -> String {
  if parent == "/" {
    "/" + name
  } else {
    parent + "/" + name
  }
}

///|
/// Assigns numbers to every node that needs one, and rewrites references into
/// cells.
///
/// The numbering follows the order in which the source first refers to each
/// node, not the order the nodes appear in the tree. That distinction is not
/// cosmetic: dtc numbers references as it resolves them, so a board that
/// refers to its clock before it refers to its interrupt controller gets 1 for
/// the clock even when the controller appears first in the file. A tree walk
/// produces a different assignment, every reference then points at the wrong
/// node, and the blob is still structurally valid — which is why the byte
/// comparison against dtc is the only test that catches it.
///
/// References under `/aliases` do not count. They become path strings rather
/// than phandles, so a node reached only through an alias gets no number.
pub fn resolve_references(file : SourceFile) -> SourceFile raise ResolveError {
  let table : LabelTable = { labels: Map([]), explicit: Map([]), }
  collect_labels(file.root, ROOT_PATH, table)
  let order : Array[String] = []
  let assigned : Map[String, UInt32] = Map([])
  for (path, value) in table.explicit {
    assigned.set(path, value)
  }
  collect_reference_order(file.root, table, order)
  let mut next = 1U
  for path in order {
    match assigned.get(path) {
      Some(_) => ()
      None => {
        assigned.set(path, next)
        next = next + 1U
      }
    }
  }
  let root = rewrite_node(file.root, ROOT_PATH, table, assigned)
  { ..file, root, }
}

///|
/// Records the path of every reference target in first-use order.
fn collect_reference_order(
  node : SourceNode,
  table : LabelTable,
  order : Array[String],
) -> Unit raise ResolveError {
  // Neither the aliases nor a node's own labels make a reference. Walking the
  // properties before the children matches source order closely enough: dtc
  // resolves in file order, and properties are written before children in
  // every source this has been checked against.
  if node.name != "aliases" {
    for prop in node.properties {
      collect_order_value(prop.value.parts, table, order)
    }
  }
  for child in node.children {
    collect_reference_order(child, table, order)
  }
}

///|
/// Appends the targets of one value's references to `order`, skipping repeats.
fn collect_order_value(
  parts : Array[ValuePart],
  table : LabelTable,
  order : Array[String],
) -> Unit raise ResolveError {
  for part in parts {
    match part {
      Ref(label) =>
        match table.labels.get(label) {
          Some(path) => push_unique(order, path)
          None => raise UnknownLabel(label~)
        }
      PathRef(path) => push_unique(order, path)
      Refs(inner) => collect_order_value(inner, table, order)
      _ => ()
    }
  }
}

///|
/// Appends a path if it is not already in the list.
///
/// The list is short — a board has tens of referenced nodes, not thousands —
/// so a linear scan is cheaper than keeping a second map in step with it.
fn push_unique(order : Array[String], path : String) -> Unit {
  for existing in order {
    if existing == path {
      return
    }
  }
  order.push(path)
}

///|
/// Produces a copy of the tree with every reference replaced by a cell and
/// every node carrying a phandle property where one was assigned.
fn rewrite_node(
  node : SourceNode,
  path : String,
  table : LabelTable,
  assigned : Map[String, UInt32],
) -> SourceNode raise ResolveError {
  let properties : Array[SourceProperty] = []
  // `/aliases` is the one node where a reference becomes a path string rather
  // than a phandle. dtc writes it that way because an alias names a node for a
  // consumer that has no idea which number the node received; the kernel
  // resolves the path at boot.
  let in_aliases = node.name == "aliases"
  for prop in node.properties {
    let parts = if in_aliases {
      rewrite_alias_parts(prop.value.parts, table)
    } else {
      rewrite_parts(prop.value.parts, table, assigned)
    }
    properties.push({ ..prop, value: Value::{ parts, }, })
  }
  // An assigned phandle becomes a property, placed where dtc puts it: after
  // the properties the source declared, since dtc appends it during the same
  // walk rather than reordering what it read.
  match assigned.get(path) {
    Some(value) =>
      if explicit_phandle(node) is None {
        properties.push({
          name: "phandle",
          value: Value::{
            parts: [Cells([value.reinterpret_as_int().to_uint64()])],
          },
          span: Span::{ line: 0, column: 0, },
        })
      }
    None => ()
  }
  let children : Array[SourceNode] = []
  for child in node.children {
    children.push(
      rewrite_node(child, join_path(path, child.name), table, assigned),
    )
  }
  { ..node, properties, children, }
}

///|
/// Rewrites the references of a property under `/aliases`.
///
/// An alias value is a path, not a phandle: `serial0 = &uart;` becomes the
/// string `"/soc/serial@1000"`. dtc does this because an alias names a node
/// for a consumer that has no idea which number the node was given, and the
/// kernel resolves the path at boot.
fn rewrite_alias_parts(
  parts : Array[ValuePart],
  table : LabelTable,
) -> Array[ValuePart] raise ResolveError {
  let out : Array[ValuePart] = []
  for part in parts {
    match part {
      Ref(label) =>
        match table.labels.get(label) {
          Some(path) => out.push(Text(path))
          None => raise UnknownLabel(label~)
        }
      PathRef(path) => out.push(Text(path))
      Refs(inner) => {
        let flat = rewrite_alias_parts(inner, table)
        for p in flat {
          out.push(p)
        }
      }
      _ => out.push(part)
    }
  }
  out
}

///|
/// Rewrites references inside a value.
fn rewrite_parts(
  parts : Array[ValuePart],
  table : LabelTable,
  assigned : Map[String, UInt32],
) -> Array[ValuePart] raise ResolveError {
  let out : Array[ValuePart] = []
  for part in parts {
    match part {
      Ref(label) =>
        match table.labels.get(label) {
          Some(path) =>
            match assigned.get(path) {
              Some(v) => out.push(Cells([v.reinterpret_as_int().to_uint64()]))
              None => raise UnknownLabel(label~)
            }
          None => raise UnknownLabel(label~)
        }
      PathRef(path) =>
        match assigned.get(path) {
          Some(v) => out.push(Cells([v.reinterpret_as_int().to_uint64()]))
          None => raise UnknownPath(path~)
        }
      Refs(inner) => {
        // An interleaved list collapses into one cell list once every piece
        // has a byte form. dtc writes it the same way: the parts are
        // contiguous in the output, so there is nothing left to distinguish.
        let flat = rewrite_parts(inner, table, assigned)
        for p in flat {
          match p {
            Cells(cells) => out.push(Cells(cells))
            other => out.push(other)
          }
        }
      }
      _ => out.push(part)
    }
  }
  out
}
