// Parser for the device tree source format.
//
// The grammar this covers is the subset that firmware sources actually use:
// `/dts-v1/`, rooted node definitions, typed and untyped property values,
// labels, references, and the delete and omit directives. The C preprocessor
// is deliberately out of scope — kernel sources run `cpp` before `dtc` and
// that step stays the caller's job, which is stated in the README rather than
// half-implemented here.
//
// Parsing produces the same `Node`/`Property` types the binary reader
// produces, so every consumer of a tree works with either source unchanged.

///|
/// The kinds of thing a property value can hold once parsed.
///
/// This is the intermediate form between the source text and the bytes the
/// binary format stores. Strings, cells and byte strings all end up in one
/// value buffer, but they go in differently, and a reference cannot be encoded
/// at all until phandles are assigned, so the distinction has to survive until
/// the encoding pass.
pub(all) enum ValuePart {
  /// A string, stored with its NUL terminator.
  Text(String)
  /// A cell list, stored as big-endian 32-bit words.
  Cells(Array[UInt64])
  /// A byte string from `[...]`, stored as-is.
  Bytes(Array[Byte])
  /// `&label`, resolvable only once every node has been named.
  Ref(String)
  /// `&{/path/to/node}`, an explicit path reference.
  PathRef(String)
  /// A reference written outside `<...>`, as in `aliases { x = &uart0; };`.
  ///
  /// This is a different construct from `Ref`, not a variation of it: dtc's
  /// grammar turns a bare `dt_ref` into a REF_PATH marker and a `<&label>` into
  /// a REF_PHANDLE one. The first becomes the target's path as a string, the
  /// second its 32-bit phandle. Emitting a phandle for the bare form produces a
  /// blob with a number where a path belongs, which no consumer can use.
  PathString(String)
  /// A cell list with references mixed in, which can only be flattened once
  /// phandles exist.
  Refs(Array[ValuePart])
  /// `/bits/ N <...>`, stored with the declared element width.
  TypedCells(UInt64, Array[UInt64])
}

///|
/// A property value: one or more parts concatenated.
///
/// `reg = <0 1>, <2 3>` and `compatible = "a", "b"` are both a list of one
/// kind, while `mixed = "x", <1>` is legal too. Keeping the parts separate
/// means the encoder does not have to re-parse the bytes to find the seams.
pub(all) struct Value {
  /// The parts in source order.
  parts : Array[ValuePart]
}

///|
/// Every way a source file can fail to parse.
///
/// Distinct from `LexerError`, which is about characters, and from `DtbError`,
/// which is about a binary blob. A caller can therefore report the three
/// failure modes differently, which matters when the input came from a user
/// pasting text.
pub(all) suberror ParseError {
  /// A token turned up where the grammar did not allow it.
  Unexpected(token~ : TokenKind, expected~ : String, span~ : Span)
  /// The scanner failed; carried through so that callers need one error type.
  Lexical(inner~ : LexerError)
  /// A value that cannot be represented in the binary form.
  BadValue(detail~ : String, span~ : Span)
  /// Nesting beyond the limit, which matches the binary reader's limit so that
  /// a tree that parses can also be written out.
  LimitExceeded(what~ : String, limit~ : Int32)
  /// A construct this version does not implement, named so the user knows
  /// what to work around rather than getting a generic syntax error.
  Unsupported(what~ : String, span~ : Span)
}

///|
/// Renders a parse error with its position.
pub impl Show for ParseError with fn output(self, logger) {
  let text = match self {
    Unexpected(token~, expected~, span~) =>
      "\{span}: expected \{expected}, found \{token}"
    Lexical(inner~) => inner.to_string()
    BadValue(detail~, span~) => "\{span}: \{detail}"
    LimitExceeded(what~, limit~) => "\{what} exceeds the limit of \{limit}"
    Unsupported(what~, span~) => "\{span}: unsupported: \{what}"
  }
  logger.write_string(text)
}

///|
/// Exposes the parse error message as a plain method.
pub extend ParseError with Show::{to_string, output}

///|
/// A parsed source file: the root node plus the memory reservations declared
/// before it.
///
/// The two are kept apart because the blob stores them in different blocks and
/// the reservation map is not part of the node tree.
pub(all) struct SourceFile {
  /// The root node, named "" for `/`.
  root : SourceNode
  /// Reservations from `/memreserve/` in source order.
  memreserves : Array[(UInt64, UInt64)]
  /// Whether the file declared `/plugin/`, which changes how missing
  /// references are treated.
  is_plugin : Bool
  /// Top-level patches from a plugin source, in order. A non-plugin file has
  /// none, and a plugin normally has no root node either.
  fragments : Array[Fragment]
}

///|
/// A property in the source tree, before its value is encoded.
pub(all) struct SourceProperty {
  /// The property name.
  name : String
  /// The parsed value, not yet encoded.
  value : Value
  /// Where the name appeared.
  span : Span
}

///|
/// One top-level patch in a plugin source, written `&label { ... }`.
///
/// The compiler turns each of these into a `fragment@N` node holding a
/// `target` reference and an `__overlay__` subtree, which is what the binary
/// form stores. They are kept separate here rather than folded at parse time
/// so that a file with no fragments still parses as a plain tree.
pub(all) struct Fragment {
  /// The label or path the patch applies to.
  target : ValuePart
  /// Where the fragment appeared.
  span : Span
  /// The properties and children the patch adds.
  node : SourceNode
}

///|
/// A node in the source tree, before references are resolved.
///
/// This is deliberately a different type from the binary `Node`: a source
/// property holds unresolved references and typed cell lists, neither of which
/// has a byte representation until the whole file has been read and phandles
/// assigned. The conversion happens in one pass afterwards, so the encoder
/// never has to look ahead.
pub(all) struct SourceNode {
  /// The node name, including any `@unit` suffix.
  name : String
  /// Labels bound to this node, in source order.
  mut labels : Array[String]
  /// Properties in source order.
  properties : Array[SourceProperty]
  /// Children in source order.
  children : Array[SourceNode]
  /// `/delete-property/` names, applied to this node after its own properties
  /// are collected.
  ///
  /// Kept as a list rather than applied during parsing because the deletion may
  /// name a property that comes later in the body, which dtc allows: the
  /// directives are collected and run once the body is closed.
  deletes : Array[String]
  /// Whether this node was introduced by `deleted` rather than by a body.
  ///
  /// A `/delete-node/` marker carries no properties or children; it exists so
  /// that the merge pass knows to remove the target instead of adding to it.
  is_delete : Bool
  /// For an `/omit-if-no-ref/` node, whether it was marked. The pass that
  /// assigns phandles drops it when nothing refers to it.
  omit_if_no_ref : Bool
}

///|
/// Parser state: the scanner plus one token of lookahead.
///
/// One token is enough for this grammar. The only construct that needs to
/// choose between alternatives by looking further is a node body, where an
/// identifier may be followed by `{`, `=` or `;` — and the token right after
/// the identifier settles which. Directives need two tokens of lookahead
/// (`/`, word, `/`), which `directive_word` gets by cloning the scanner
/// instead of buffering.
pub(all) struct Parser {
  /// The scanner, positioned just past `current`.
  lexer : Lexer
  /// The token the parser is looking at.
  mut current : Token
}

///|
/// Reads one token from the scanner, converting a scanner error into the
/// parser's error type so callers only handle one.
fn Parser::advance(self : Parser) -> Unit raise ParseError {
  let next = self.lexer.next() catch { e => raise Lexical(inner=e) }
  self.current = next
}

///|
/// Creates a parser positioned at the first token.
pub fn Parser::new(source : String) -> Parser raise ParseError {
  let lexer = Lexer::new(source)
  let first = lexer.next() catch { e => raise Lexical(inner=e) }
  Parser::{ lexer, current: first, }
}

///|
/// Fails unless the current token is `kind`, naming what was expected.
fn Parser::expect(
  self : Parser,
  kind : TokenKind,
  what : String,
) -> Token raise ParseError {
  if not_same_kind(self.current.kind, kind) {
    raise Unexpected(
      token=self.current.kind,
      expected=what,
      span=self.current.span,
    )
  }
  self.current
}

///|
/// Compares two token kinds for the purpose of `expect`.
///
/// Payload-carrying kinds compare by shape only: the caller asking for an
/// `Ident` wants any identifier, and asking for the payload as well would mean
/// constructing a dummy value at every call site.
fn not_same_kind(a : TokenKind, b : TokenKind) -> Bool {
  match (a, b) {
    (Ident(_), Ident(_)) => false
    (String(_), String(_)) => false
    (Number(_), Number(_)) => false
    (LBrace, LBrace)
    | (RBrace, RBrace)
    | (LAngle, LAngle)
    | (RAngle, RAngle)
    | (LBracket, LBracket)
    | (RBracket, RBracket)
    | (LParen, LParen)
    | (RParen, RParen)
    | (Comma, Comma)
    | (Semicolon, Semicolon)
    | (Equals, Equals)
    | (Slash, Slash)
    | (Amp, Amp)
    | (Colon, Colon)
    | (Minus, Minus)
    | (Plus, Plus)
    | (Star, Star)
    | (Percent, Percent)
    | (Tilde, Tilde)
    | (Bang, Bang)
    | (Caret, Caret)
    | (Pipe, Pipe)
    | (Question, Question)
    | (Eof, Eof) => false
    // Two operators are the same kind when they are the same operator; the
    // payload is what distinguishes them, so it is compared rather than
    // ignored.
    (RelOp(a), RelOp(b)) => !same_rel_op(a, b)
    _ => true
  }
}

///|
/// Whether two operators are the same one.
fn same_rel_op(a : RelOp, b : RelOp) -> Bool {
  match (a, b) {
    (Less, Less)
    | (Greater, Greater)
    | (LessEqual, LessEqual)
    | (GreaterEqual, GreaterEqual)
    | (EqualEqual, EqualEqual)
    | (NotEqual, NotEqual)
    | (ShiftLeft, ShiftLeft)
    | (ShiftRight, ShiftRight) => true
    _ => false
  }
}

///|
/// Whether the scanner is at the end.
fn Parser::at_eof(self : Parser) -> Bool {
  match self.current.kind {
    Eof => true
    _ => false
  }
}

///|
/// Parses a whole source file.
///
/// The leading `/dts-v1/;` is required: without it the file is not a device
/// tree source, and treating it as one would accept a fragment as if it were
/// complete. `/plugin/;` may appear after it and is recorded rather than
/// acted on, because its only effect is on how unresolved references are
/// reported.
pub fn parse_source(source : String) -> SourceFile raise ParseError {
  let parser = Parser::new(source)
  let memreserves : Array[(UInt64, UInt64)] = []
  let mut is_plugin = false
  let mut saw_version = false
  // Patches that follow the root node in this same file. Collected here so
  // that they outlive the branch that reads them.
  let patches : Array[Fragment] = []
  while !parser.at_eof() {
    if parser.is_slash_directive("dts-v1") {
      if saw_version {
        raise BadValue(
          detail="/dts-v1/ appears more than once",
          span=parser.current.span,
        )
      }
      parser.consume_directive("dts-v1")
      parser.expect_kind(Semicolon, "';' after /dts-v1/")
      parser.advance()
      saw_version = true
    } else if parser.is_slash_directive("plugin") {
      parser.consume_directive("plugin")
      parser.expect_kind(Semicolon, "';' after /plugin/")
      parser.advance()
      is_plugin = true
    } else if parser.is_slash_directive("memreserve") {
      let span = parser.current.span
      parser.consume_directive("memreserve")
      let (address, next) = parser.take_number("an address after /memreserve/")
      let (size, _) = parser.take_number("a size after the address")
      ignore(next)
      parser.expect_kind(Semicolon, "';'")
      parser.advance()
      memreserves.push((address, size))
      ignore(span)
    } else {
      // The root node is the only node at top level. A file without one is a
      // fragment, which this version does not support because there is no
      // well-defined parent to attach it to.
      break
    }
  }
  if !saw_version {
    raise BadValue(
      detail="missing /dts-v1/; directive",
      span=parser.current.span,
    )
  }
  // A plugin may consist only of `&label { ... }` patches, so an empty file
  // after the directives is legal there. A plain source still needs its root
  // node.
  let fragments : Array[Fragment] = []
  let root : SourceNode = if parser.at_eof() {
    // A plugin still needs at least a trailing `;` after `/plugin/` — dtc's
    // grammar is `versioninfo plugindecl memreserves devicetree`, and a file
    // that stops before the devicetree is a syntax error there. Accepting an
    // empty plugin here would compile a source dtc refuses, which is the one
    // thing the comparison tests exist to prevent.
    raise BadValue(detail="no root node", span=parser.current.span)
  } else if parser.starts_fragment() {
    // Every top-level entry is a patch. The root node stays empty; the
    // fragments carry everything the file said.
    while !parser.at_eof() {
      fragments.push(parser.parse_fragment())
    }
    {
      name: "",
      labels: [],
      properties: [],
      children: [],
      deletes: [],
      is_delete: false,
      omit_if_no_ref: false,
    }
  } else {
    let node = parser.parse_node("")
    // Everything after the root node is one of three things: another root
    // block to merge, a `/delete-node/` marker, or a patch. dtc accepts all
    // three in any order, which is what lets an `/include/` bring in a root
    // block of its own.
    let mut current = node
    while !parser.at_eof() {
      if parser.is_slash_directive("delete-node") {
        // Applied at the point it is read, not after the file, because a later
        // root block can revive what this removes: a node deleted here and
        // re-declared below keeps its earlier properties and reappears in the
        // output. Collecting these and running them last would delete the
        // revival instead of the original.
        let marker = parser.parse_delete_node()
        current = apply_reference_deletion(current, marker)
        continue
      }
      // A bare `/` opens another root block. A directive also starts with a
      // slash, so the word after it decides: `directive_word` returns None for
      // `/ {`, which is what makes this the root-block branch.
      if same_kind(parser.current.kind, Slash) &&
        parser.directive_word() is None {
        let extra = parser.parse_node("")
        current = merge_source_node(current, extra)
        continue
      }
      // `&label { ... };` after the root node is a patch, not only a plugin
      // construct: dtc applies it to the tree it just read, which is how a
      // board file overrides a node from an included file.
      //
      // Applied here rather than collected, because dtc's grammar action runs
      // the merge the moment it reduces: a patch written before a
      // `/delete-node/` sees the node, and one written after it does not. That
      // ordering is observable — the patch either succeeds or reports an
      // unknown label.
      if parser.starts_fragment() {
        current = apply_patch_now(current, parser.parse_fragment())
        continue
      }
      raise Unexpected(
        token=parser.current.kind,
        expected="end of file after the root node",
        span=parser.current.span,
      )
    }
    current
  }
  let resolved = apply_deletions(root)
  // `patches` is empty for a plain source now that each patch is applied as it
  // is read. It is non-empty only for a plugin, whose fragments are the output
  // rather than edits to a tree.
  let patched = apply_self_patches(resolved, patches)
  // Two children of one node sharing a name is an error, and the check belongs
  // here rather than in the parser: dtc runs it over the finished tree and
  // skips nodes flagged deleted, so a name declared twice is only a duplicate
  // if the first of the two was not removed by a `/delete-node/` marker in
  // between. Checking while reading the body would reject sources dtc accepts.
  check_duplicate_children(patched)
  { root: patched, memreserves, is_plugin, fragments, }
}

///|
/// Rejects two live children of one node that share a name.
///
/// This mirrors dtc's `check_duplicate_node_names`, including the part of it
/// that looks like a bug. The outer loop skips deleted children; the inner one
/// does not. Both consequences are observable, and a compiler that tidied the
/// asymmetry away would disagree with dtc in both directions:
///
/// * Marking a node in the same body it was declared in is an error, because
///   the marker sits after the node and the inner scan finds a live child
///   followed by a tombstone of the same name:
///
///       a@1 { ... };
///       /delete-node/ a@1;      // duplicate
///
/// * Declaring the same node in two root blocks without a marker is also an
///   error, because `merge_nodes` leaves both in the list:
///
///       / { a@1 { ... }; };  / { a@1 { ... }; };   // duplicate
///
/// The same body in the opposite order is *not* an error — the marker names a
/// sibling that has not been merged yet, so it deletes nothing and leaves a
/// tombstone the outer loop skips. That case is covered by the tests.
fn check_duplicate_children(node : SourceNode) -> Unit raise ParseError {
  for i in 0..<node.children.length() {
    if node.children[i].is_delete {
      continue
    }
    for j in (i + 1)..<node.children.length() {
      if node.children[i].name == node.children[j].name {
        raise BadValue(
          detail="duplicate node name '\{node.children[j].name}'",
          span={ line: 1, column: 1, },
        )
      }
    }
  }
  for child in node.children {
    if !child.is_delete {
      check_duplicate_children(child)
    }
  }
}

///|
/// Applies one top-level `/delete-node/ &label;` or `&{/path};` to the tree
/// built so far.
///
/// Resolving and marking here rather than in a final pass is what makes the
/// directive behave like dtc's: the grammar action runs the deletion the moment
/// it reduces, so a later root block merges into a node that is already flagged
/// and revives it, exactly as it would for the bare-name form. An unknown
/// target is an error, which is the reference form's behaviour and not the
/// bare-name form's.
fn apply_reference_deletion(
  root : SourceNode,
  marker : SourceNode,
) -> SourceNode raise ParseError {
  let labels = collect_label_paths(root)
  let target = marker.name
  let path = if target.has_prefix("&{") {
    target[2:target.length() - 1].to_owned()
  } else if target.has_prefix("&") {
    let label = target[1:].to_owned()
    match labels.get(label) {
      Some(p) => p
      None =>
        raise BadValue(detail="/delete-node/ names unknown label '\{label}'", span={
          line: 1,
          column: 1,
        })
    }
  } else {
    raise BadValue(
      detail="/delete-node/ needs '&label' or '&{/path}', found '\{target}'",
      span={ line: 1, column: 1, },
    )
  }
  let segments = path_segments(path)
  // An empty path cannot name a node: the root is never deletable, because
  // there has to be a tree left to write.
  if segments.length() == 0 {
    raise BadValue(detail="/delete-node/ cannot name the root node", span={
      line: 1,
      column: 1,
    })
  }
  // An unknown label and a label whose path does not resolve are separate
  // failures in dtc, and a path that names nothing must not be a silent no-op:
  // `&{/b}` inside `/ { a { b { }; }; }` is missing the `a` segment, and dtc
  // says so rather than deleting nothing.
  match mark_by_path(root, segments, 0) {
    Some(next) => next
    None =>
      raise BadValue(detail="/delete-node/ names unknown path '\{path}'", span={
        line: 1,
        column: 1,
      })
  }
}

///|
/// Flags the node at `segments` as deleted, leaving it in place.
///
/// Returns `None` when the path does not resolve, so the caller can report it.
/// The reference form rejects an unknown target; that is the difference from the
/// bare-name form, which is a silent no-op when it finds nothing.
fn mark_by_path(
  node : SourceNode,
  segments : Array[String],
  depth : Int32,
) -> SourceNode? {
  let want = segments[depth]
  let last = depth == segments.length() - 1
  let children : Array[SourceNode] = []
  let mut matched = false
  let mut resolved = false
  for child in node.children {
    if child.is_delete || child.name != want {
      children.push(child)
      continue
    }
    matched = true
    if last {
      children.push(strip_deleted(child))
      resolved = true
    } else {
      // The segment matched but the rest of the path may still not exist, which
      // is a different failure from "this segment is not here" and is reported
      // the same way: the path as a whole does not resolve.
      match mark_by_path(child, segments, depth + 1) {
        Some(deeper) => {
          children.push(deeper)
          resolved = true
        }
        None => children.push(child)
      }
    }
  }
  if !matched || !resolved {
    return None
  }
  Some({ ..node, children, })
}

///|
/// Consumes `expect_kind`'s kind after checking it.
fn Parser::expect_kind(
  self : Parser,
  kind : TokenKind,
  what : String,
) -> Unit raise ParseError {
  ignore(self.expect(kind, what))
}

///|
/// Whether the cursor is at `/word`, which is how this grammar recognises a
/// directive.
///
/// `tag_after_slash` peeks past the slash by taking the token after it, which
/// costs one token of the parser's lookahead rather than re-lexing the source.
fn Parser::is_slash_directive(self : Parser, word : String) -> Bool {
  if not_same_kind(self.current.kind, Slash) {
    return false
  }
  // The scanner has already advanced past the slash in `current`; the word is
  // whatever the lexer returns next, so it is peeked by cloning the lexer.
  let ahead = self.lexer.clone()
  let token = ahead.next() catch { _ => return false }
  match token.kind {
    Ident(name) => name == word
    _ => false
  }
}

///|
/// Whether `a` and `b` are the same kind, for the places that need it without
/// the `expect` machinery.
fn same_kind(a : TokenKind, b : TokenKind) -> Bool {
  !not_same_kind(a, b)
}

///|
/// Consumes `/word/` in one step.
fn Parser::consume_directive(
  self : Parser,
  word : String,
) -> Unit raise ParseError {
  ignore(word)
  self.expect_kind(Slash, "'/'")
  self.advance()
  self.expect_kind(Ident(word), "the directive name")
  self.advance()
  self.expect_kind(Slash, "'/' closing the directive")
  self.advance()
}

///|
/// Consumes an integer token and returns its value.
fn Parser::take_number(
  self : Parser,
  what : String,
) -> (UInt64, Span) raise ParseError {
  let span = self.current.span
  match self.current.kind {
    Number(n) => {
      self.advance()
      (n, span)
    }
    other => raise Unexpected(token=other, expected=what, span~)
  }
}

///|
/// Parses a node: an optional label, a name, then a brace-delimited body.
///
/// The root node's name is the empty string, which is what `/` produces. Body
/// contents are dispatched on the token that starts them: an identifier may
/// introduce either a child node or a property, and `/` may introduce a
/// directive, so the parser reads the identifier first and decides from the
/// token after it.
fn Parser::parse_node(
  self : Parser,
  name : String,
) -> SourceNode raise ParseError {
  // A node at the top level is written as `/ { ... };` — the name is the
  // slash itself, which the caller has already consumed for the root. Child
  // nodes arrive with their name already read from the body loop.
  let node_name = if name == "" {
    if same_kind(self.current.kind, Slash) {
      self.advance()
      ""
    } else {
      raise Unexpected(
        token=self.current.kind,
        expected="'/' starting the root node",
        span=self.current.span,
      )
    }
  } else {
    name
  }
  // One body parser for both: a root node and a child node differ only in how
  // the name was decided, and keeping two copies meant the directives added
  // below landed in one of them.
  self.parse_node_body(node_name)
}

///|
/// Consumes an identifier token.
fn Parser::take_ident(
  self : Parser,
  what : String,
) -> (String, Span) raise ParseError {
  let span = self.current.span
  match self.current.kind {
    Ident(name) => {
      self.advance()
      (name, span)
    }
    other => raise Unexpected(token=other, expected=what, span~)
  }
}

///|
/// Reads the word between two slashes without consuming anything, or None if
/// the tokens after the slash are not `/word/`.
fn Parser::directive_word(self : Parser) -> String? {
  let ahead = self.lexer.clone()
  let first = ahead.next() catch { _ => return None }
  match first.kind {
    Ident(word) => {
      let second = ahead.next() catch { _ => return None }
      match second.kind {
        Slash => Some(word)
        _ => None
      }
    }
    _ => None
  }
}

///|
/// Parses the part of a property after its name: `= value;` or just `;` for
/// the boolean form.
fn Parser::parse_property(
  self : Parser,
  name : String,
  span : Span,
) -> SourceProperty raise ParseError {
  let value = if same_kind(self.current.kind, Equals) {
    self.advance()
    self.parse_value()
  } else {
    // A bare `name;` is a boolean property: present means true, and the encoded
    // form is a zero-length value.
    { parts: [], }
  }
  self.expect_kind(Semicolon, "';' after a property value")
  self.advance()
  { name, value, span, }
}

///|
/// Parses a property value: one or more parts separated by commas.
///
/// A comma between parts is the only separator the format has; whitespace and
/// newlines are insignificant. `&` introduces a reference that may point at a
/// label or, with braces, at a full path.
fn Parser::parse_value(self : Parser) -> Value raise ParseError {
  let parts : Array[ValuePart] = []
  while true {
    let part = self.parse_value_part()
    parts.push(part)
    if same_kind(self.current.kind, Comma) {
      self.advance()
      continue
    }
    break
  }
  Value::{ parts, }
}

///|
/// Parses one part of a value.
///
/// `/bits/ 8 <...>` and `/incbin/` are the two directives that can appear at
/// the start of a part. `bits` is handled because it changes how the cells are
/// encoded; `incbin` is not, because reading an external file would make the
/// parse depend on the file system and the format's byte output depends on
/// data outside the source.
fn Parser::parse_value_part(self : Parser) -> ValuePart raise ParseError {
  if same_kind(self.current.kind, Slash) {
    let directive = self.directive_word()
    match directive {
      Some("bits") => return self.parse_bits()
      Some("incbin") =>
        raise Unsupported(what="/incbin/", span=self.current.span)
      _ =>
        raise Unexpected(
          token=self.current.kind,
          expected="a value",
          span=self.current.span,
        )
    }
  }
  self.parse_plain_part()
}

///|
/// Parses the parts that have no directive prefix.
fn Parser::parse_plain_part(self : Parser) -> ValuePart raise ParseError {
  let span = self.current.span
  match self.current.kind {
    String(s) => {
      self.advance()
      Text(s)
    }
    LAngle => self.parse_cells()
    LBracket => self.parse_byte_string()
    Amp =>
      // A bare reference outside `<...>` is a path string, not a phandle. The
      // two forms look alike and produce completely different values, so the
      // distinction is made here, where the surrounding syntax is still known.
      match self.parse_reference() {
        Ref(label) => PathString("&" + label)
        PathRef(path) => PathString("&{" + path + "}")
        other => other
      }
    Number(_) =>
      // A bare number outside `<...>` is not legal DTS. Reporting it as such is
      // more useful than letting the encoder produce an empty value.
      raise BadValue(detail="a number must be inside '<...>'", span~)
    _ =>
      raise Unexpected(
        token=self.current.kind,
        expected="a string, '<...>', '[...]' or '&reference'",
        span~,
      )
  }
}

///|
/// Parses `<...>`, a list of 32-bit cells.
///
/// Parenthesised expressions (`<(1 << 4)>`) are not evaluated: the format
/// passes them to the C preprocessor in practice, and evaluating them here
/// would disagree with dtc on anything the preprocessor was meant to handle.
fn Parser::parse_cells(self : Parser) -> ValuePart raise ParseError {
  self.expect_kind(LAngle, "'<'")
  self.advance()
  let cells : Array[UInt64] = []
  let mut saw_reference = false
  let refs : Array[ValuePart] = []
  while !self.at_eof() {
    if same_kind(self.current.kind, RAngle) {
      self.advance()
      // A cell list that contains a reference cannot be a plain cell list: the
      // reference has to be resolved to a phandle first, and a phandle is a
      // cell like any other. Folding it back into the cell list is the
      // encoder's job, so it is returned here as a reference with the
      // surrounding cells recorded on either side.
      if saw_reference {
        refs.push(Cells(cells.copy()))
        return Refs(refs.copy())
      }
      return Cells(cells)
    }
    if same_kind(self.current.kind, Amp) {
      let r = self.parse_reference()
      refs.push(Cells(cells.copy()))
      refs.push(r)
      cells.clear()
      saw_reference = true
      continue
    }
    match self.current.kind {
      Number(n) => {
        if n > 0xFFFF_FFFFUL {
          raise BadValue(
            detail="cell value \{n} does not fit in 32 bits",
            span=self.current.span,
          )
        }
        cells.push(n)
        self.advance()
      }
      // `( ... )` is an expression, evaluated now and stored as the number it
      // works out to. dtc does the same: the blob has no trace of it.
      LParen => {
        let span = self.current.span
        let value = self.parse_expression()
        let masked = mask_to_width(value, 32UL)
        if masked > 0xFFFF_FFFFUL {
          raise BadValue(
            detail="cell value \{masked} does not fit in 32 bits",
            span~,
          )
        }
        cells.push(masked)
      }
      _ =>
        raise Unexpected(
          token=self.current.kind,
          expected="a cell value or '>'",
          span=self.current.span,
        )
    }
  }
  raise Unexpected(
    token=self.current.kind,
    expected="'>' closing the cell list",
    span=self.current.span,
  )
}

///|
/// Parses `[...]`, a byte string.
///
/// Bytes are written as pairs of hex digits, optionally separated by
/// whitespace. dtc also accepts a single digit per byte in older sources but
/// rejects it now, so this follows the current rule.
fn Parser::parse_byte_string(self : Parser) -> ValuePart raise ParseError {
  self.expect_kind(LBracket, "'['")
  self.advance()
  let bytes : Array[Byte] = []
  while !self.at_eof() {
    if same_kind(self.current.kind, RBracket) {
      self.advance()
      return Bytes(bytes)
    }
    match self.current.kind {
      HexByte(b) => {
        bytes.push(b)
        self.advance()
      }
      _ =>
        raise Unexpected(
          token=self.current.kind,
          expected="a pair of hex digits or ']'",
          span=self.current.span,
        )
    }
  }
  raise Unexpected(
    token=self.current.kind,
    expected="']' closing the byte string",
    span=self.current.span,
  )
}

///|
/// Parses a reference: `&label` or `&{/path/to/node}`.
fn Parser::parse_reference(self : Parser) -> ValuePart raise ParseError {
  self.expect_kind(Amp, "'&'")
  self.advance()
  match self.current.kind {
    Ident(label) => {
      self.advance()
      Ref(label)
    }
    LBrace => {
      self.advance()
      let parts : Array[String] = []
      while !self.at_eof() {
        if same_kind(self.current.kind, RBrace) {
          self.advance()
          return PathRef("/" + join_segments(parts))
        }
        match self.current.kind {
          Ident(seg) => {
            parts.push(seg)
            self.advance()
          }
          Slash => self.advance()
          other =>
            raise Unexpected(
              token=other,
              expected="a path segment or '}'",
              span=self.current.span,
            )
        }
      }
      raise Unexpected(
        token=self.current.kind,
        expected="'}' closing the path reference",
        span=self.current.span,
      )
    }
    other =>
      raise Unexpected(
        token=other,
        expected="a label or '{' after '&'",
        span=self.current.span,
      )
  }
}

///|
/// Joins path segments with slashes.
fn join_segments(parts : Array[String]) -> String {
  let buf = StringBuilder()
  let mut first = true
  for p in parts {
    if !first {
      buf.write_string("/")
    }
    first = false
    buf.write_string(p)
  }
  buf.to_string()
}

///|
/// Parses `/bits/ N <...>`.
///
/// The bits directive changes cell width: 8, 16, 32 or 64 bits per element.
/// dtc writes the result as a byte string rather than as cells, so the parse
/// records the width and the encoder emits bytes.
fn Parser::parse_bits(self : Parser) -> ValuePart raise ParseError {
  ignore(self.directive_word())
  self.consume_directive("bits")
  let (width, _) = self.take_number("a width after /bits/")
  let valid = width == 8UL || width == 16UL || width == 32UL || width == 64UL
  if !valid {
    raise BadValue(
      detail="/bits/ width must be 8, 16, 32 or 64",
      span=self.current.span,
    )
  }
  self.expect_kind(LAngle, "'<' after /bits/ width")
  self.advance()
  let cells : Array[UInt64] = []
  while !self.at_eof() {
    if same_kind(self.current.kind, RAngle) {
      self.advance()
      return TypedCells(width, cells)
    }
    match self.current.kind {
      Number(n) => {
        let max = if width == 64UL {
          0xFFFF_FFFF_FFFF_FFFFUL
        } else {
          (1UL << width.to_int()) - 1UL
        }
        if n > max {
          raise BadValue(
            detail="value does not fit in \{width} bits",
            span=self.current.span,
          )
        }
        cells.push(n)
        self.advance()
      }
      _ =>
        raise Unexpected(
          token=self.current.kind,
          expected="a cell value or '>'",
          span=self.current.span,
        )
    }
  }
  raise Unexpected(
    token=self.current.kind,
    expected="'>' closing the cell list",
    span=self.current.span,
  )
}

///|
/// Whether the next top-level construct is a `&label { ... }` patch.
///
/// The token after `&` is either an identifier or `{`, and a plain reference
/// never appears at top level, so seeing `&` here is unambiguous.
fn Parser::starts_fragment(self : Parser) -> Bool {
  same_kind(self.current.kind, Amp)
}

///|
/// Parses one `&target { ... }` patch.
///
/// The node body is parsed by the same code a normal node uses, so properties,
/// children and nested labels all behave the same inside a patch.
fn Parser::parse_fragment(self : Parser) -> Fragment raise ParseError {
  let span = self.current.span
  let target = self.parse_reference()
  let node = self.parse_node_body("__overlay__")
  { target, span, node, }
}

///|
/// Parses a brace-delimited body under a caller-supplied name.
///
/// Extracted from `parse_node` so a fragment can reuse it: the difference
/// between a node and a patch is only how the name was decided.
fn Parser::parse_node_body(
  self : Parser,
  name : String,
) -> SourceNode raise ParseError {
  self.expect_kind(LBrace, "'{' opening the node body")
  self.advance()
  let properties : Array[SourceProperty] = []
  let children : Array[SourceNode] = []
  let node_labels : Array[String] = []
  let deletes : Array[String] = []
  let mut omit_if_no_ref = false
  while !self.at_eof() {
    if same_kind(self.current.kind, RBrace) {
      self.advance()
      self.expect_kind(Semicolon, "';' after '}'")
      self.advance()
      return {
        name,
        labels: node_labels.copy(),
        properties,
        children,
        deletes,
        is_delete: false,
        omit_if_no_ref,
      }
    }
    // Directives are checked before the identifier rule, because they start
    // with a slash and would otherwise be read as a node name.
    if same_kind(self.current.kind, Slash) {
      match self.directive_word() {
        Some("delete-node") => {
          // A `/delete-node/` inside a body names a sibling by its node name,
          // not by a reference: the parent is already known, so there is nothing
          // for a label to resolve. dtc's grammar has exactly this production
          // (`subnode: DT_DEL_NODE DT_PROPNODENAME ';'`), and the rules about
          // what it can reach are strict enough that reproducing them matters:
          // the marker is merged in like any other child, so it only removes a
          // sibling that has already been merged, and it never deletes the node
          // whose body it sits in — which is what makes
          //
          //     a@1 { ... };
          //     /delete-node/ a@1;      // removes the node above
          //
          //     /delete-node/ a@1;      // removes nothing: nothing merged yet
          //     a@1 { ... };            // so this one survives
          //
          // behave differently. Because the merge is per root block, a later
          // root block also cannot delete a node an earlier one added, which is
          // why the same construct inside a second `/ { soc { ... } }` silently
          // does nothing in dtc.
          self.eat_directive("delete-node")
          let (target, target_span) = self.take_ident(
            "a node name after /delete-node/",
          )
          self.expect_kind(Semicolon, "';' after /delete-node/")
          self.advance()
          ignore(target_span)
          children.push({
            name: target,
            labels: [],
            properties: [],
            children: [],
            deletes: [],
            is_delete: true,
            omit_if_no_ref: false,
          })
          continue
        }
        Some("delete-property") => {
          deletes.push(self.parse_delete_property())
          continue
        }
        Some("omit-if-no-ref") => {
          self.eat_directive("omit-if-no-ref")
          // The marker applies to the node that follows, which the loop reads
          // on the next pass; the flag is consumed there.
          omit_if_no_ref = true
          continue
        }
        _ => ()
      }
    }
    let (ident, ident_span) = self.take_ident("a node or property name")
    if same_kind(self.current.kind, Colon) {
      self.advance()
      node_labels.push(ident)
      ignore(ident_span)
      continue
    }
    let eq = same_kind(self.current.kind, Equals)
    let semi = same_kind(self.current.kind, Semicolon)
    let is_property = eq || semi
    if is_property {
      // dtc's grammar only allows a property definition in the `proplist` that
      // precedes every subnode, so a property written after a child is a syntax
      // error there. It used to fall through to a parse error here as well, but
      // only by accident: the arm that reported it was the catch-all. Naming it
      // keeps the message the same as dtc's.
      if children.length() > 0 {
        raise Unexpected(
          token=self.current.kind,
          expected="properties must precede subnodes",
          span=ident_span,
        )
      }
      properties.push(self.parse_property(ident, ident_span))
      continue
    }
    if same_kind(self.current.kind, LBrace) {
      let child = self.parse_node(ident)
      children.push({ ..child, labels: node_labels.copy(), omit_if_no_ref, })
      node_labels.clear()
      omit_if_no_ref = false
      continue
    }
    raise Unexpected(
      token=self.current.kind,
      expected="'{', '=' or ';' after an identifier",
      span=self.current.span,
    )
  }
  raise Unexpected(
    token=self.current.kind,
    expected="'}' closing the node body",
    span=self.current.span,
  )
}

// ---------------------------------------------------------------------------
// Expressions
//
// The precedence table is a list of levels from loosest to tightest binding.
// Each level parses its operands and then loops while the next token is one of
// its operators, which is what makes `1 + 2 * 3` group the way C does. The
// alternative — a Pratt parser — needs the same table and an extra
// bookkeeping field, so the table is written out here as data.
// ---------------------------------------------------------------------------

///|
/// Parses `( expr )` and returns the evaluated value.
///
/// The parentheses are part of the source rather than of the grammar: dtc only
/// enters expression mode when it sees `(`, so a bare `1 + 2` outside them is a
/// syntax error there too.
fn Parser::parse_expression(self : Parser) -> Int64 raise ParseError {
  let span = self.current.span
  self.expect_kind(LParen, "'(' opening an expression")
  self.advance()
  let expr = self.parse_ternary()
  self.expect_kind(RParen, "')' closing the expression")
  self.advance()
  eval_expr(expr) catch {
    e => raise BadValue(detail=expr_error_text(e), span~)
  }
}

///|
/// Renders an `ExprError` for a parse error message.
fn expr_error_text(e : ExprError) -> String {
  match e {
    DivisionByZero => "division by zero in an expression"
    BadShift(amount~) => "shift by \{amount} is outside 0..63"
    Overflow(what~) => "arithmetic overflow: \{what}"
  }
}

///|
/// `cond ? yes : no`, right associative.
fn Parser::parse_ternary(self : Parser) -> Expr raise ParseError {
  let cond = self.parse_binary(0)
  if same_kind(self.current.kind, Question) {
    self.advance()
    let yes = self.parse_ternary()
    self.expect_kind(Colon, "':' in a conditional expression")
    self.advance()
    let no = self.parse_ternary()
    return Ternary(cond, yes, no)
  }
  cond
}

///|
/// The binary levels, loosest first. Each entry lists the operators at that
/// level; `parse_binary(level)` handles level and everything tighter.
fn bin_op_for(kind : TokenKind, level : Int32) -> BinOp? {
  match level {
    0 =>
      match kind {
        Pipe => Some(Or)
        _ => None
      }
    1 =>
      match kind {
        Caret => Some(Xor)
        _ => None
      }
    2 =>
      match kind {
        Amp => Some(And)
        _ => None
      }
    3 =>
      match kind {
        RelOp(EqualEqual) => Some(Eq)
        RelOp(NotEqual) => Some(Ne)
        _ => None
      }
    4 =>
      // Bare `<` and `>` arrive as the bracket tokens, because the scanner
      // cannot tell a comparison from a cell list without context. Inside an
      // expression the parser has that context, so both spellings map to the
      // same operator here.
      match kind {
        RelOp(Less) => Some(Lt)
        RelOp(LessEqual) => Some(Le)
        RelOp(Greater) => Some(Gt)
        RelOp(GreaterEqual) => Some(Ge)
        LAngle => Some(Lt)
        RAngle => Some(Gt)
        _ => None
      }
    5 =>
      match kind {
        RelOp(ShiftLeft) => Some(Shl)
        RelOp(ShiftRight) => Some(Shr)
        _ => None
      }
    6 =>
      match kind {
        Plus => Some(Add)
        Minus => Some(Sub)
        _ => None
      }
    7 =>
      match kind {
        Star => Some(Mul)
        Slash => Some(Div)
        Percent => Some(Mod)
        _ => None
      }
    _ => None
  }
}

///|
/// Parses one precedence level, recursing into the next tighter one.
fn Parser::parse_binary(self : Parser, level : Int32) -> Expr raise ParseError {
  if level > 7 {
    return self.parse_unary()
  }
  let mut left = self.parse_binary(level + 1)
  while true {
    let op = bin_op_for(self.current.kind, level)
    match op {
      None => break
      Some(op) => {
        self.advance()
        let right = self.parse_binary(level + 1)
        left = Bin(op, left, right)
      }
    }
  }
  left
}

///|
/// Parses a unary operator or an atom.
fn Parser::parse_unary(self : Parser) -> Expr raise ParseError {
  match self.current.kind {
    Minus => {
      self.advance()
      Un(Neg, self.parse_unary())
    }
    Tilde => {
      self.advance()
      Un(Not, self.parse_unary())
    }
    Bang => {
      self.advance()
      Un(LogicalNot, self.parse_unary())
    }
    LParen => {
      // A nested group, which is how `((1 + 2) * 3)` is written.
      self.advance()
      let inner = self.parse_ternary()
      self.expect_kind(RParen, "')' closing the group")
      self.advance()
      inner
    }
    Number(n) => {
      // The literal is unsigned in the token; the evaluator works signed, and
      // going through the two halves keeps a full-width hex literal such as
      // `0xFFFFFFFFFFFFFFFF` as the negative number C would see rather than
      // truncating it.
      let hi = ((n >> 32) & 0xFFFF_FFFFUL).to_int()
      let lo = (n & 0xFFFF_FFFFUL).to_int()
      let value = (hi.reinterpret_as_uint().to_int64() << 32) |
        lo.reinterpret_as_uint().to_int64()
      self.advance()
      Lit(value)
    }
    other =>
      raise Unexpected(
        token=other,
        expected="a number or a unary operator",
        span=self.current.span,
      )
  }
}

// ---------------------------------------------------------------------------
// Deletion and omission directives
//
// `/delete-node/`, `/delete-property/` and `/omit-if-no-ref/` are part of the
// DTS grammar rather than of any preprocessor: dtc reads them itself. Two of
// them are markers that change what a node means, and one removes something
// the same file declared earlier, so all three are resolved after the source
// has been read rather than during the scan.
// ---------------------------------------------------------------------------

///|
/// Consumes the `/word/` under the cursor, if it is `word`.
///
/// The slash, the identifier and the closing slash are three tokens; the
/// caller has already established that they spell a directive.
fn Parser::eat_directive(self : Parser, word : String) -> Unit raise ParseError {
  ignore(word)
  self.expect_kind(Slash, "'/' opening a directive")
  self.advance()
  self.expect_kind(Ident(word), "the directive name")
  self.advance()
  self.expect_kind(Slash, "'/' closing the directive")
  self.advance()
}

///|
/// Parses `/delete-node/ <target>;` where the target is a label, a path, or a
/// bare name.
///
/// A bare name is what appears inside a node body, where the parent is already
/// known; at top level dtc wants `&label` or `&{/path}` because there is no
/// parent to resolve a bare name against.
fn Parser::parse_delete_node(self : Parser) -> SourceNode raise ParseError {
  self.eat_directive("delete-node")
  let name = match self.current.kind {
    Amp =>
      // A reference: reuses the same grammar as a cell value's reference, so
      // `&label` and `&{/path}` both work.
      match self.parse_reference() {
        Ref(label) => "&" + label
        PathRef(path) => "&{" + path + "}"
        other => {
          ignore(other)
          raise Unexpected(
            token=self.current.kind,
            expected="a label or path after /delete-node/",
            span=self.current.span,
          )
        }
      }
    other =>
      // dtc accepts only a reference here: a bare name would be ambiguous with
      // a node of that name in the same body, and dtc reports it as a duplicate
      // rather than deleting anything. Matching that keeps a source that
      // compiles here compiling there.
      raise Unexpected(
        token=other,
        expected="a label or path after /delete-node/",
        span=self.current.span,
      )
  }
  self.expect_kind(Semicolon, "';' after /delete-node/")
  self.advance()
  {
    name,
    labels: [],
    properties: [],
    children: [],
    deletes: [],
    is_delete: true,
    omit_if_no_ref: false,
  }
}

///|
/// Parses `/delete-property/ <name>;` and returns the name.
fn Parser::parse_delete_property(self : Parser) -> String raise ParseError {
  self.eat_directive("delete-property")
  let (name, _) = self.take_ident("a property name after /delete-property/")
  self.expect_kind(Semicolon, "';' after /delete-property/")
  self.advance()
  name
}

///|
/// Applies `/delete-node/` and `/delete-property/` across the whole tree.
///
/// The two forms of `/delete-node/` are not the same operation, and conflating
/// them is what makes a compiler disagree with dtc on ordinary board sources.
///
/// `&label` and `&{/path}` name a node from anywhere in the file and are
/// resolved against the completed tree, which is why the label table is
/// collected first: a directive at the top of a file may name a label declared
/// at the bottom.
///
/// A bare name is a different thing entirely. It sits inside a node body and
/// means "remove the sibling I just merged", so it is applied during the merge
/// rather than afterwards — see `absorb_child`. Resolving it here against an
/// absolute path would make it delete more than dtc does.
fn apply_deletions(root : SourceNode) -> SourceNode raise ParseError {
  // The full path, not the last segment: a deletion target is matched against
  // the path a node sits at, and `d1` alone would never equal `/d1`.
  let labels = collect_label_paths(root)
  let removed : Map[String, Bool] = Map([])
  collect_delete_paths(root, labels, "", removed)
  remove_paths(root, removed, "")
}

///|
/// Walks the tree turning reference deletion markers into absolute paths.
///
/// Only the `&label` and `&{/path}` forms reach this pass. A bare name is
/// consumed by the merge, and by the time the tree is built there is nothing
/// left for it to name.
fn collect_delete_paths(
  node : SourceNode,
  labels : Map[String, String],
  path : String,
  acc : Map[String, Bool],
) -> Unit raise ParseError {
  for child in node.children {
    if !child.is_delete {
      continue
    }
    let target = child.name
    if target.has_prefix("&{") {
      acc.set(target[2:target.length() - 1].to_owned(), true)
    } else if target.has_prefix("&") {
      let label = target[1:].to_owned()
      match labels.get(label) {
        Some(p) => acc.set(p, true)
        None =>
          raise BadValue(
            detail="/delete-node/ names unknown label '\{label}'",
            span={ line: 1, column: 1, },
          )
      }
    }
    // A bare name: already handled by the merge, nothing to record.
  }
  for child in node.children {
    if child.is_delete {
      continue
    }
    let child_path = if path == "" {
      "/" + child.name
    } else {
      path + "/" + child.name
    }
    collect_delete_paths(child, labels, child_path, acc)
  }
}

///|
/// Drops the nodes whose path is in `removed`, and applies each node's own
/// `/delete-property/` list.
fn remove_paths(
  node : SourceNode,
  removed : Map[String, Bool],
  path : String,
) -> SourceNode {
  // `/delete-property/` written directly in a node body has no effect: dtc
  // accepts the syntax and ignores it, because the directive only means
  // something against a node the file is patching, and a body that declares a
  // property is not patching anything. Removing it here would make this
  // compiler disagree with dtc on a source both accept, which is the one thing
  // the comparison tests exist to prevent.
  let properties = node.properties
  let kept : Array[SourceNode] = []
  for child in node.children {
    let child_path = if path == "" {
      "/" + child.name
    } else {
      path + "/" + child.name
    }
    if removed.get(child_path) is Some(_) {
      // A reference deletion is a property of the *target*, so it is applied
      // here by marking the node rather than by unlinking it. dtc keeps the
      // node in the tree with `deleted` set and skips it in the writers, and
      // keeping it matters: `check_duplicate_node_names` reads the list, so
      // whether a node was marked or removed changes which sources report a
      // duplicate.
      kept.push({ ..child, is_delete: true, })
      continue
    }
    kept.push(remove_paths(child, removed, child_path))
  }
  { ..node, properties, children: kept, deletes: [], }
}

///|
/// Splits `/a/b/c` into its segments, dropping the empty leading one.
fn path_segments(path : String) -> Array[String] {
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
/// Applies `&label { ... }` patches that appeared in the same file as the tree.
///
/// A patch modifies a node the file already declared. The merge is the same
/// one an overlay performs — properties named in the patch replace, children
/// merge, everything else survives — so it is written here against the source
/// tree rather than against the binary one, because at this point neither
/// phandles nor a blob exist yet.
fn apply_self_patches(
  root : SourceNode,
  patches : Array[Fragment],
) -> SourceNode raise ParseError {
  let labels = collect_label_paths(root)
  let mut current = root
  for patch in patches {
    let path = match patch.target {
      Ref(label) =>
        match labels.get(label) {
          Some(p) => p
          None =>
            raise BadValue(
              detail="reference to unknown label '\{label}'",
              span=patch.span,
            )
        }
      PathRef(p) => p
      _ =>
        raise BadValue(detail="patch target is not a reference", span={
          line: 1,
          column: 1,
        })
    }
    current = merge_source_path(current, path, patch.node)
  }
  current
}

///|
/// Applies one `&label { ... };` patch to the tree built so far.
///
/// The label table is rebuilt from the current tree on every call, so a label
/// on a node a previous patch added is visible, and a label on a node a
/// previous deletion removed is not. Rebuilding is O(nodes) per patch; a
/// device tree has thousands of nodes and a file has a handful of patches, so
/// the cost is irrelevant next to getting the ordering right.
fn apply_patch_now(
  root : SourceNode,
  patch : Fragment,
) -> SourceNode raise ParseError {
  let labels = collect_label_paths(root)
  let path = match patch.target {
    Ref(label) =>
      match labels.get(label) {
        Some(p) => p
        None =>
          raise BadValue(
            detail="reference to unknown label '\{label}'",
            span=patch.span,
          )
      }
    PathRef(p) => p
    _ =>
      raise BadValue(detail="patch target is not a reference", span={
        line: 1,
        column: 1,
      })
  }
  merge_source_path(root, path, patch.node)
}

///|
/// Maps each label to the full path of its node.
///
/// The full path is what makes a nested patch work: `&intc` on a node two
/// levels down has to resolve to `/soc/interrupt-controller@1000`, and
/// carrying only the last segment would make the walk match the wrong sibling.
fn collect_label_paths(root : SourceNode) -> Map[String, String] {
  let acc : Map[String, String] = Map([])
  walk_label_paths(root, "", acc)
  acc
}

///|
/// Recursive worker for `collect_label_paths`.
fn walk_label_paths(
  node : SourceNode,
  prefix : String,
  acc : Map[String, String],
) -> Unit {
  let here = if node.name == "" { "/" } else { prefix + "/" + node.name }
  for label in node.labels {
    acc.set(label, here)
  }
  for child in node.children {
    if !child.is_delete {
      walk_label_paths(child, if node.name == "" { "" } else { here }, acc)
    }
  }
}

///|
/// Merges a patch into the node at `path`, returning the new root.
///
/// The path is walked segment by segment, so the recursion knows the parent it
/// is in and can replace the child it names. A path that names nothing is an
/// error: a patch that silently did nothing would make a board file build and
/// behave as though the override were absent.
fn merge_source_path(
  node : SourceNode,
  path : String,
  patch : SourceNode,
) -> SourceNode raise ParseError {
  let segments = path_segments(path)
  merge_at(node, segments, 0, patch, "")
}

///|
/// Walks `segments[at..]` looking for the node to merge into.
fn merge_at(
  node : SourceNode,
  segments : Array[String],
  at : Int32,
  patch : SourceNode,
  here : String,
) -> SourceNode raise ParseError {
  if at >= segments.length() {
    return merge_source_node(node, patch)
  }
  let wanted = segments[at]
  let out : Array[SourceNode] = []
  let mut found = false
  for child in node.children {
    if child.name == wanted {
      let merged = merge_at(child, segments, at + 1, patch, here + "/" + wanted)
      out.push(merged)
      found = true
    } else {
      out.push(child)
    }
  }
  if !found {
    raise BadValue(detail="patch target '\{here}/\{wanted}' does not exist", span={
      line: 1,
      column: 1,
    })
  }
  { ..node, children: out, }
}

///|
/// Merges one patch body into one node.
///
/// Properties replace by name, `/delete-property/` removes from the result, and
/// children merge by name so that a patch touching one property keeps the
/// node's other children.
fn merge_source_node(node : SourceNode, patch : SourceNode) -> SourceNode {
  // dtc's `merge_nodes` walks the incoming properties and, for each one, either
  // overwrites the existing property *in place* or appends it. Overwriting in
  // place rather than dropping the old one and appending is what keeps the
  // property order stable: a node whose `compatible` is overridden keeps
  // `compatible` where it was rather than having it move to the end.
  let mut properties : Array[SourceProperty] = node.properties.copy()
  for deleted in patch.deletes {
    let kept : Array[SourceProperty] = []
    for prop in properties {
      if prop.name != deleted {
        kept.push(prop)
      }
    }
    properties = kept
  }
  for incoming in patch.properties {
    let mut replaced = false
    for i in 0..<properties.length() {
      if properties[i].name == incoming.name {
        properties[i] = incoming
        replaced = true
        break
      }
    }
    if !replaced {
      properties.push(incoming)
    }
  }
  // Children are absorbed one at a time, in source order, because that is what
  // makes an in-body `/delete-node/ <name>` behave the way it does in dtc: the
  // marker removes the sibling that has already been merged and nothing else.
  // Doing the deletions in a second pass over the finished list would let a
  // marker delete a sibling declared after it, which dtc does not do.
  let mut children : Array[SourceNode] = node.children.copy()
  for incoming in patch.children {
    children = absorb_child(children, incoming)
  }
  // Merging into a node revives it if it had been deleted, which is dtc's
  // `old_node->deleted = 0` at the top of `merge_nodes`.
  { ..node, properties, children, is_delete: false, }
}

///|
/// Merges one child into a parent's child list, honouring a deletion marker.
///
/// `deleted` is dtc's `node->deleted`: a `/delete-node/ <name>` parsed inside a
/// body becomes a child whose only job is to remove the sibling of that name.
/// The removal looks at what has been merged so far, so
///
///     /delete-node/ a@1;   a@1 { ... };    // the node survives
///     a@1 { ... };         /delete-node/ a@1;   // the node is a duplicate
///
/// differ. The first leaves a tombstone that the duplicate check skips; the
/// second leaves a live node followed by a tombstone of the same name, which
/// dtc's asymmetric check reports as an error. That second outcome is not a
/// deletion at all, which is the part that reads as a bug.
///
/// A marker whose name matches no sibling is a silent no-op rather than an
/// error: the reference form at top level is the one that rejects an unknown
/// target.
fn absorb_child(
  children : Array[SourceNode],
  incoming : SourceNode,
) -> Array[SourceNode] {
  if incoming.is_delete {
    for i in 0..<children.length() {
      if children[i].name == incoming.name {
        // The marker deletes the *contents* as well as flagging the node, which
        // is dtc's `delete_node` reached through `delete_node_by_name`. This is
        // the case where the marker is a sibling of its target: the parent
        // being merged into holds the target, and the target loses everything.
        children[i] = strip_deleted(children[i])
        break
      }
    }
    return children
  }
  for i in 0..<children.length() {
    if children[i].name == incoming.name {
      // Merging into a tombstone revives it, exactly as `merge_nodes` clears
      // `old_node->deleted` before copying anything across.
      children[i] = merge_source_node(children[i], incoming)
      return children
    }
  }
  children.push(incoming)
  return children
}

///|
/// Flags a node as deleted and strips everything it held.
///
/// This is dtc's `delete_node`, which walks the target's children and
/// properties and marks each one deleted as well. Anything a later declaration
/// does not restate is therefore gone, which is why a reference deletion that a
/// later root block revives comes back carrying only the new declaration's
/// properties.
///
/// The node itself stays in the list rather than being unlinked, so a later
/// declaration of the same name still finds it and merges into it. dtc's
/// `merge_nodes` clears the flag on the way in, which is what "revives" means.
fn strip_deleted(node : SourceNode) -> SourceNode {
  { ..node, is_delete: true, labels: [], properties: [], children: [], }
}

///|
