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
      deletes: [],
      is_delete: false,
      omit_if_no_ref: false,
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
      deletes: [],
      is_delete: false,
      omit_if_no_ref: false,
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
  {
    name: "__fixups__",
    labels: [],
    properties,
    children: [],
    deletes: [],
    is_delete: false,
    omit_if_no_ref: false,
  }
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

///|
/// A parsed overlay ready to be applied: the fragments it carries and the
/// fixups that name where each unresolved reference landed.
pub(all) struct Overlay {
  /// Blob the overlay was read from, kept so error messages can name a
  /// position.
  blob : Tree
  /// Fragment nodes, in the order the blob lists them.
  fragments : Array[Node]
  /// Label to the locations that need the label's phandle written into them.
  fixups : Array[(String, Array[FixupLocation])]
}

///|
/// One place a label's phandle has to be written.
///
/// `path` is the node, `property` the property on it, and `offset` the byte
/// offset inside that property's value. This is the same triple dtc writes
/// into `__fixups__` as a single string.
pub(all) struct FixupLocation {
  /// Node path, with `/` for the root.
  path : String
  /// Property name.
  property : String
  /// Byte offset inside the value.
  offset : Int32
}

///|
/// Reads an overlay blob.
///
/// The fixup strings are parsed here rather than at apply time so that a
/// malformed one is reported when the overlay is read, not halfway through
/// patching a tree.
pub fn parse_overlay(tree : Tree) -> Overlay raise OverlayError {
  let fragments : Array[Node] = []
  for child in tree.root.children {
    if child.name.has_prefix("fragment@") {
      fragments.push(child)
    }
  }
  let fixups : Array[(String, Array[FixupLocation])] = []
  match find_child(tree.root, "__fixups__") {
    Some(node) =>
      for prop in node.properties {
        let entries : Array[FixupLocation] = []
        // One property holds one label; several locations for it are separated
        // by a NUL in the value, which is how dtc stores a string list.
        for text in split_cstr_list(prop.value) {
          entries.push(parse_fixup_location(text))
        }
        fixups.push((prop.name, entries))
      }
    None => ()
  }
  { blob: tree, fragments, fixups, }
}

///|
/// Finds a direct child by name.
fn find_child(node : Node, name : String) -> Node? {
  for child in node.children {
    if child.name == name {
      return Some(child)
    }
  }
  None
}

///|
/// Splits a value into the NUL-terminated strings it holds.
fn split_cstr_list(value : Bytes) -> Array[String] {
  let out : Array[String] = []
  let bounds = Bounds::of_bytes(value)
  let mut at = 0L
  while at < bounds.length() {
    let (text, next) = bounds.cstr(at, bounds.length()) catch { _ => break }
    out.push(text)
    at = next
  }
  out
}

///|
/// Parses `/path/to/node:property:offset`.
///
/// The path itself contains slashes but no colons, so the last two colons
/// delimit the parts unambiguously.
fn parse_fixup_location(text : String) -> FixupLocation raise OverlayError {
  let last = text.rev_find(":")
  match last {
    None => raise BadFixup(detail="not a /path:property:offset string: " + text)
    Some(at) => {
      let head = text[:at].to_owned()
      let offset_text = text[at + 1:].to_owned()
      let offset = match str_to_int(offset_text) {
        Some(n) => n
        None => raise BadFixup(detail="offset is not a number in " + text)
      }
      match head.rev_find(":") {
        None => raise BadFixup(detail="no property in " + text)
        Some(sep) => {
          let path = head[:sep].to_owned()
          let property = head[sep + 1:].to_owned()
          { path, property, offset, }
        }
      }
    }
  }
}

///|
/// Parses a non-negative decimal integer, or None.
///
/// Hand-rolled because the standard conversion raises on bad input and this
/// call site wants to report the whole fixup string instead of the one field.
fn str_to_int(text : String) -> Int32? {
  if text.length() == 0 {
    return None
  }
  let mut value = 0
  for i in 0..<text.length() {
    let c = text.get_char(i).unwrap()
    if c < '0' || c > '9' {
      return None
    }
    value = value * 10 + (c.to_int() - 0x30)
  }
  Some(value)
}

///|
/// Applies an overlay to a base tree and returns the merged tree.
///
/// The procedure is the one the Linux loader follows. Each fragment names a
/// node in the base tree — either through the label recorded in the overlay's
/// `__fixups__`, or directly through `target-path` — and carries an
/// `__overlay__` subtree. That subtree's properties are set on the target,
/// replacing what was there, and its children are merged into children of the
/// same name, creating them where the base has none.
///
/// Merging rather than replacing is the whole point: an overlay that sets one
/// property on a node keeps the base tree's other properties on it.
pub fn apply_overlay(base : Tree, overlay : Overlay) -> Tree raise OverlayError {
  let symbols = match find_child(base.root, "__symbols__") {
    Some(node) => symbols_of(node)
    None => raise NoSymbols
  }
  // The fixups are what turn a label into a path: an overlay built from
  // `&uart0 { ... }` has a placeholder in `fragment@0/target` and a fixup
  // naming `uart0` for that exact property.
  let targets : Map[String, String] = Map([])
  for (label, locations) in overlay.fixups {
    match symbols.get(label) {
      Some(path) =>
        for location in locations {
          // The location is `/fragment@N:target:0`; the fragment name is the
          // last path segment and is what the map is keyed on.
          targets.set(location.path, path)
        }
      None => raise UnknownSymbol(label~)
    }
  }
  let phandles = phandles_of(base.root)
  let mut root = base.root
  for fragment in overlay.fragments {
    let target_path = fragment_target_path(fragment, targets)
    let body = match find_child(fragment, "__overlay__") {
      Some(node) => node
      None => raise BadFragment(name=fragment.name)
    }
    root = merge_into(root, target_path, body)
  }
  // Placeholder words in the applied body are now resolvable: the base tree
  // gave those nodes their numbers.
  root = patch_placeholders(root, overlay, symbols, phandles)
  { root, warnings: base.warnings, memreserves: base.memreserves, }
}

///|
/// Works out which node a fragment applies to.
fn fragment_target_path(
  fragment : Node,
  targets : Map[String, String],
) -> String raise OverlayError {
  // A `target-path` property names the node outright, which is what an overlay
  // built without -@ carries.
  let by_property = match find_property(fragment, "target-path") {
    Some(prop) => {
      let value = Bounds::of_bytes(prop.value)
      let text = value.cstr(0L, value.length()) catch { _ => ("", 0L) }
      if text.0 == "" {
        None
      } else {
        Some(text.0)
      }
    }
    None => None
  }
  match by_property {
    Some(path) => path
    None => {
      let key = "/" + fragment.name
      match targets.get(key) {
        Some(path) => path
        None => raise BadFragment(name=fragment.name)
      }
    }
  }
}

///|
/// Reads `__symbols__` into a label-to-path map.
fn symbols_of(node : Node) -> Map[String, String] {
  let out : Map[String, String] = Map([])
  for prop in node.properties {
    let value = Bounds::of_bytes(prop.value)
    let text = value.cstr(0L, value.length()) catch { _ => continue }
    out.set(prop.name, text.0)
  }
  out
}

///|
/// Reads every node's phandle, keyed by path.
fn phandles_of(node : Node) -> Map[String, UInt32] {
  let out : Map[String, UInt32] = Map([])
  walk_phandles(node, "/", out)
  out
}

///|
/// Depth-first walk collecting phandles.
fn walk_phandles(node : Node, path : String, out : Map[String, UInt32]) -> Unit {
  for prop in node.properties {
    if prop.name == "phandle" && prop.value.length() == 4 {
      let value = Bounds::of_bytes(prop.value)
      let read = value.read_u32(Cursor::big(0L)) catch { _ => continue }
      out.set(path, read.0)
    }
  }
  for child in node.children {
    walk_phandles(child, join_path(path, child.name), out)
  }
}

///|
/// Merges an overlay body into the node at `path`.
///
/// Properties from the body replace properties of the same name and are
/// appended otherwise, which is the order the loader produces and what a
/// subsequent dump shows. Children merge recursively by name.
fn merge_into(root : Node, path : String, body : Node) -> Node {
  if path == "/" {
    return merge_node(root, body)
  }
  let segments = split_path(path)
  set_child(root, segments, 0, body)
}

///|
/// Splits `/soc/serial@2000` into `["soc", "serial@2000"]`.
fn split_path(path : String) -> Array[String] {
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
/// Replaces the child named by `segments[at]` with `body`, recursing for the
/// remaining segments and creating a node where none exists.
fn set_child(
  node : Node,
  segments : Array[String],
  at : Int32,
  body : Node,
) -> Node {
  if at >= segments.length() {
    return merge_node(node, body)
  }
  let name = segments[at]
  let children : Array[Node] = []
  let mut found = false
  for child in node.children {
    if child.name == name {
      found = true
      children.push(set_child(child, segments, at + 1, body))
    } else {
      children.push(child)
    }
  }
  if !found {
    // The path names a node the base tree does not have. dtc reports this;
    // here an empty node is created so that the fragment still lands
    // somewhere, and the caller can compare against dtc to catch it.
    let mut fresh : Node = { name, properties: [], children: [], }
    fresh = set_child(fresh, segments, at + 1, body)
    children.push(fresh)
  }
  { ..node, children, }
}

///|
/// Merges one node's properties and children into another.
fn merge_node(base : Node, body : Node) -> Node {
  let mut properties = base.properties.copy()
  for prop in body.properties {
    // A property the base already has is replaced where it stands, and a new
    // one is inserted at the *front* of the list. That is what libfdt does:
    // `fdt_setprop` resizes in place when the name exists and otherwise calls
    // `fdt_add_property_`, which splices the new FDT_PROP tag at
    // `fdt_check_node_offset_` — the position of the first property.
    //
    // The consequence is visible: an overlay that adds three properties puts
    // them in reverse order ahead of everything the base declared. Appending
    // them at the end instead produces the same set of properties in a
    // different order, which is a different blob and a different `dtc -O dts`
    // dump.
    let replaced : Array[Property] = []
    let mut hit = false
    for existing in properties {
      if existing.name == prop.name {
        replaced.push(prop)
        hit = true
      } else {
        replaced.push(existing)
      }
    }
    if hit {
      properties = replaced
    } else {
      properties = [prop] + properties
    }
  }
  let children = base.children.copy()
  for child in body.children {
    let merged : Array[Node] = []
    let mut hit = false
    for existing in children {
      if existing.name == child.name {
        merged.push(merge_node(existing, child))
        hit = true
      } else {
        merged.push(existing)
      }
    }
    children.clear()
    for c in merged {
      children.push(c)
    }
    if !hit {
      children.push(child)
    }
  }
  { ..base, properties, children, }
}

///|
/// Replaces every placeholder word with the phandle the base tree assigned.
///
/// The overlay's own fixups name where the placeholders are, so this walks
/// those locations rather than scanning the tree for 0xffffffff: a real cell
/// value can legitimately be that number, and rewriting it would corrupt an
/// unrelated property.
fn patch_placeholders(
  root : Node,
  overlay : Overlay,
  symbols : Map[String, String],
  phandles : Map[String, UInt32],
) -> Node {
  let mut current = root
  // The paths in the fixups address the overlay, not the merged tree: a
  // location is `/fragment@0/__overlay__:interrupt-parent:0`, while the node
  // it belongs to after merging is wherever the fragment's target pointed.
  let targets : Map[String, String] = Map([])
  for (label, locations) in overlay.fixups {
    for location in locations {
      match targets.get(location.path) {
        Some(_) => ()
        None =>
          match symbols.get(label) {
            Some(path) => targets.set(location.path, path)
            None => ()
          }
      }
    }
  }
  for (label, locations) in overlay.fixups {
    match symbols.get(label) {
      None => continue
      Some(target_path) =>
        // A node the base tree never gave a number cannot be patched, and
        // inventing one here would produce a blob whose references disagree
        // with the tree they point into.
        match phandles.get(target_path) {
          None => continue
          Some(number) =>
            for location in locations {
              current = write_cell(
                current,
                remap_fixup_path(location.path, targets),
                location.property,
                location.offset,
                number,
              )
            }
        }
    }
  }
  current
}

///|
/// Writes a 32-bit value at a byte offset inside a property.
///
/// The path in a fixup points into the overlay tree, but the apply step merged
/// that tree into the base, so the same path addresses the merged result: the
/// fragment names survive the merge.
fn write_cell(
  root : Node,
  path : String,
  property : String,
  offset : Int32,
  value : UInt32,
) -> Node {
  let segments = split_path(path)
  update_node(root, segments, 0, property, offset, value)
}

///|
/// Recursively finds the node at `segments` and patches its property.
fn update_node(
  node : Node,
  segments : Array[String],
  at : Int32,
  property : String,
  offset : Int32,
  value : UInt32,
) -> Node {
  if at >= segments.length() {
    let properties : Array[Property] = []
    for prop in node.properties {
      if prop.name == property && offset + 4 <= prop.value.length() {
        let patched = Buffer(capacity=prop.value.length())
        for i in 0..<prop.value.length() {
          patched.write_byte(prop.value.at(i))
        }
        let raw = value.reinterpret_as_int()
        let bytes = patched.to_bytes()
        let out = Buffer(capacity=bytes.length())
        for i in 0..<bytes.length() {
          if i == offset {
            out.write_byte(((raw >> 24) & 0xFF).to_byte())
            out.write_byte(((raw >> 16) & 0xFF).to_byte())
            out.write_byte(((raw >> 8) & 0xFF).to_byte())
            out.write_byte((raw & 0xFF).to_byte())
          } else if i < offset || i >= offset + 4 {
            out.write_byte(bytes.at(i))
          }
        }
        properties.push({ ..prop, value: out.to_bytes(), })
      } else {
        properties.push(prop)
      }
    }
    return { ..node, properties, }
  }
  let name = segments[at]
  let children : Array[Node] = []
  for child in node.children {
    if child.name == name {
      children.push(
        update_node(child, segments, at + 1, property, offset, value),
      )
    } else {
      children.push(child)
    }
  }
  { ..node, children, }
}

///|
/// Finds a direct property by name.
fn find_property(node : Node, name : String) -> Property? {
  for prop in node.properties {
    if prop.name == name {
      return Some(prop)
    }
  }
  None
}

///|
/// Rewrites a fixup path from overlay coordinates to merged-tree coordinates.
///
/// `/fragment@0/__overlay__/serial@1000` addresses a node inside the fragment;
/// after the merge that node lives under the fragment's target, so the
/// `fragment@N/__overlay__` prefix is replaced by the target path. A fixup on
/// the fragment's own `target` property has no merged equivalent and is left
/// alone, which is correct: the loader consumes it rather than rewriting it.
fn remap_fixup_path(path : String, targets : Map[String, String]) -> String {
  let marker = "/__overlay__"
  match path.find(marker) {
    None => path
    Some(at) => {
      let fragment_part = path[:at].to_owned()
      let tail = path[at + marker.length():].to_owned()
      // `targets` is keyed on `/fragment@N`; the fixup path is
      // `/fragment@N/__overlay__/...`, so the same key applies.
      match targets.get(fragment_part) {
        Some(target) => if target == "/" { tail } else { target + tail }
        None => path
      }
    }
  }
}

///|
/// Decodes a blob into a tree, as the CLI and a browser caller both need.
pub fn parse_tree(blob : Bytes) -> Tree raise DtbError {
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
  let memreserves = parse_memreserves(blob, header)
  parse_struct_with(struct_bounds, strings_bounds, memreserves)
}

///|
/// Encodes a decoded tree back to a blob.
///
/// The values are already bytes at this point, so each property is written
/// through unchanged; this exists so that an applied overlay can be written
/// out without going through the source representation.
pub fn encode_tree(tree : Tree) -> Bytes {
  let strings = StringTable::new()
  let struct_block = Buffer()
  write_binary_node(tree.root, strings, struct_block)
  put_u32(struct_block, 0x9)
  let strings_bytes = strings.to_bytes()
  let struct_bytes = struct_block.to_bytes()
  let memreserve = Buffer()
  for (address, size) in tree.memreserves {
    put_u64(memreserve, address)
    put_u64(memreserve, size)
  }
  // The map is terminated by a zero pair, so even an empty one is 16 bytes.
  put_u64(memreserve, 0UL)
  put_u64(memreserve, 0UL)
  let memreserve_bytes = memreserve.to_bytes()
  let blocks = memreserve_bytes.length() + struct_bytes.length()
  let total = 40 + blocks + strings_bytes.length()
  let out = Buffer()
  put_u32(out, 0xD00D_FEED)
  put_u32(out, total.reinterpret_as_uint())
  let off_struct = 40 + memreserve_bytes.length()
  put_u32(out, off_struct.reinterpret_as_uint())
  let off_strings = off_struct + struct_bytes.length()
  put_u32(out, off_strings.reinterpret_as_uint())
  put_u32(out, 40)
  put_u32(out, 17)
  put_u32(out, 16)
  put_u32(out, 0)
  put_u32(out, strings_bytes.length().reinterpret_as_uint())
  put_u32(out, struct_bytes.length().reinterpret_as_uint())
  for i in 0..<memreserve_bytes.length() {
    out.write_byte(memreserve_bytes.at(i))
  }
  for i in 0..<struct_bytes.length() {
    out.write_byte(struct_bytes.at(i))
  }
  for i in 0..<strings_bytes.length() {
    out.write_byte(strings_bytes.at(i))
  }
  out.to_bytes()
}

///|
/// Writes a decoded node back into the struct block, values already encoded.
fn write_binary_node(node : Node, strings : StringTable, out : Buffer) -> Unit {
  put_u32(out, 0x1)
  for i in 0..<node.name.length() {
    out.write_byte(node.name.get_char(i).unwrap().to_int().to_byte())
  }
  out.write_byte((0 : Int32).to_byte())
  align_buffer(out)
  for prop in node.properties {
    let name_at = strings.intern(prop.name)
    put_u32(out, 0x3)
    put_u32(out, prop.value.length().reinterpret_as_uint())
    put_u32(out, name_at.reinterpret_as_uint())
    for i in 0..<prop.value.length() {
      out.write_byte(prop.value.at(i))
    }
    align_buffer(out)
  }
  for child in node.children {
    write_binary_node(child, strings, out)
  }
  put_u32(out, 0x2)
}
