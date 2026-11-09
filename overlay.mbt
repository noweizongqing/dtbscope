// Overlays: a tree that patches another tree.
//
// An overlay cannot know where the base tree put its nodes, so a reference in
// one is written as the reserved word 0xffffffff and recorded in
// `__fixups__` as a path to the property and the offset inside it. The loader
// reads the base tree's `__symbols__`, looks the label up, and patches the
// reserved word with the number the base gave that node.
//
// Two halves here: building an overlay from a plugin source (which is what dtc
// does with -@), and applying one to a base tree.

///|
/// The reserved word that stands in for a reference whose value only the base
/// tree knows.
const PHANDLE_PLACEHOLDER : UInt32 = 0xFFFF_FFFF

///|
/// Every way building or applying an overlay can fail.
pub(all) suberror OverlayError {
  /// The overlay refers to a label the base tree does not export.
  UnknownSymbol(label~ : String)
  /// A fixup names a node path that is not in the tree it was applied to.
  MissingTarget(path~ : String)
  /// A fixup names a property or offset that does not hold a placeholder.
  BadFixup(detail~ : String)
  /// The base tree has no `/__symbols__`, so nothing can be resolved against
  /// it.
  NoSymbols
  /// A fragment carries neither `target` nor `target-path`.
  BadFragment(name~ : String)
  /// A plugin could not be resolved for a reason other than a label the base
  /// tree supplies.
  Resolve(inner~ : ResolveError)
}

///|
/// Renders an overlay error.
pub impl Show for OverlayError with fn output(self, logger) {
  let text = match self {
    UnknownSymbol(label~) => "base tree does not export the symbol '\{label}'"
    MissingTarget(path~) => "no node at '\{path}'"
    BadFixup(detail~) => "bad fixup: \{detail}"
    NoSymbols =>
      "base tree has no /__symbols__; build it with -@ to export its labels"
    BadFragment(name~) => "fragment \{name} has neither target nor target-path"
    Resolve(inner~) => inner.to_string()
  }
  logger.write_string(text)
}

///|
/// Exposes the message as a plain method.
pub extend OverlayError with Show::{to_string, output}

///|
/// Builds an overlay from a plugin source.
///
/// The result is a normal blob whose `__fixups__` node lists where each
/// unresolved reference landed. dtc produces the same bytes for the same
/// source with `-@`.
///
/// Only references that resolve outside the overlay remain unresolved. A
/// plugin that refers to a label it defines itself gets a real phandle, which
/// is what dtc does too: the fixup list is for what the base tree has to
/// supply.
pub fn build_overlay(file : SourceFile) -> SourceFile raise OverlayError {
  if !file.is_plugin {
    raise BadFixup(detail="source is not marked /plugin/")
  }
  // Each `&label { ... }` patch becomes a `fragment@N` node holding a `target`
  // reference and an `__overlay__` subtree. dtc numbers the fragments in
  // source order starting at 0, and the fixups refer back to those names.
  let fragments : Array[SourceNode] = []
  let mut index = 0
  for fragment in file.fragments {
    let name = "fragment@\{index}"
    let target_prop : SourceProperty = {
      name: "target",
      value: Value::{ parts: [fragment.target], },
      span: fragment.span,
    }
    fragments.push({
      name,
      labels: [],
      properties: [target_prop],
      children: [fragment.node],
    })
    index = index + 1
  }
  let base_root = if file.fragments.length() > 0 {
    // A plugin with patches does not also carry a root node in practice, but a
    // file may have both; keeping the root's own children means neither is
    // lost.
    SourceNode::{
      name: "",
      labels: [],
      properties: file.root.properties,
      children: file.root.children.copy() + fragments,
    }
  } else {
    file.root
  }
  // Resolution runs first for everything the plugin can resolve on its own.
  // An unknown label is not a failure here: those are exactly the references
  // the base tree is expected to supply, and they become fixups below.
  let staged = ({ ..file, root: base_root, } : SourceFile)
  let resolved = resolve_references(staged) catch {
    UnknownLabel(_) => staged
    e => raise Resolve(inner=e)
  }
  let fixups : Array[(String, String)] = []
  let root = collect_plugin_fixups(resolved.root, "/", fixups)
  let fixup_node = build_fixup_node(fixups)
  let children = root.children.copy()
  children.push(fixup_node)
  { ..resolved, root: { ..root, children, }, }
}

///|
/// Walks a plugin tree replacing unresolved references with the placeholder
/// word and recording where each one landed.
///
/// A fixup entry is the label mapped to `"/patch/node:property:offset"`, the
/// form dtc writes and the one the Linux loader parses.
fn collect_plugin_fixups(
  node : SourceNode,
  path : String,
  fixups : Array[(String, String)],
) -> SourceNode {
  let properties : Array[SourceProperty] = []
  for prop in node.properties {
    let parts : Array[ValuePart] = []
    let mut byte_offset = 0
    for part in prop.value.parts {
      match part {
        Ref(label) => {
          parts.push(
            Cells([PHANDLE_PLACEHOLDER.reinterpret_as_int().to_uint64()]),
          )
          fixups.push((label, fixup_location(path, prop.name, byte_offset)))
          byte_offset = byte_offset + 4
        }
        PathRef(_) => {
          // A path reference names a node the overlay itself contains, so it
          // is not something the base tree supplies.
          parts.push(part)
          byte_offset = byte_offset + 4
        }
        Cells(cells) => {
          parts.push(Cells(cells))
          byte_offset = byte_offset + cells.length() * 4
        }
        Refs(inner) => {
          let replaced : Array[ValuePart] = []
          for p in inner {
            match p {
              Ref(label) => {
                replaced.push(
                  Cells([PHANDLE_PLACEHOLDER.reinterpret_as_int().to_uint64()]),
                )
                fixups.push(
                  (label, fixup_location(path, prop.name, byte_offset)),
                )
                byte_offset = byte_offset + 4
              }
              Cells(cells) => {
                replaced.push(Cells(cells))
                byte_offset = byte_offset + cells.length() * 4
              }
              other => replaced.push(other)
            }
          }
          // The pieces concatenate in the output, so they collapse to one list.
          let flat : Array[UInt64] = []
          for p in replaced {
            match p {
              Cells(cells) =>
                for c in cells {
                  flat.push(c)
                }
              _ => ()
            }
          }
          parts.push(Cells(flat))
        }
        other => {
          parts.push(other)
          byte_offset = byte_offset + value_part_length(other)
        }
      }
    }
    properties.push({ ..prop, value: Value::{ parts, }, })
  }
  let children : Array[SourceNode] = []
  for child in node.children {
    children.push(
      collect_plugin_fixups(child, join_path(path, child.name), fixups),
    )
  }
  { ..node, properties, children, }
}

///|
/// Formats a fixup location the way dtc does: `/path/to/node:property:offset`.
fn fixup_location(path : String, property : String, offset : Int32) -> String {
  "\{path}:\{property}:\{offset}"
}

///|
/// Length in bytes of a value part, used to track the offset a fixup points at.
fn value_part_length(part : ValuePart) -> Int32 {
  match part {
    Text(s) => s.length() + 1
    Cells(cells) => cells.length() * 4
    TypedCells(width, cells) => width.to_int() / 8 * cells.length()
    Bytes(bs) => bs.length()
    _ => 4
  }
}

///|
/// Groups fixups by label and builds the `__fixups__` node.
///
/// One label can appear at several places, and dtc lists them in the order the
/// walk found them, comma-separated in a single string property.
fn build_fixup_node(fixups : Array[(String, String)]) -> SourceNode {
  let order : Array[String] = []
  let grouped : Map[String, Array[String]] = Map([])
  for (label, location) in fixups {
    match grouped.get(label) {
      Some(list) => list.push(location)
      None => {
        let list : Array[String] = [location]
        grouped.set(label, list)
        order.push(label)
      }
    }
  }
  let properties : Array[SourceProperty] = []
  for label in order {
    match grouped.get(label) {
      Some(list) => {
        let joined = join_strings(list, ":")
        // dtc separates multiple locations for one label with a colon in the
        // path and nothing between entries, which keeps the value a single
        // NUL-terminated string.
        properties.push({
          name: label,
          value: Value::{ parts: [Text(joined)], },
          span: Span::{ line: 0, column: 0, },
        })
      }
      None => ()
    }
  }
  { name: "__fixups__", labels: [], properties, children: [], }
}

///|
/// Joins strings with a separator.
fn join_strings(values : Array[String], sep : String) -> String {
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
