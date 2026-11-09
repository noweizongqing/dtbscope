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
    | (Eof, Eof) => false
    _ => true
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
  if parser.at_eof() {
    raise BadValue(detail="no root node", span=parser.current.span)
  }
  let root = parser.parse_node("")
  if !parser.at_eof() {
    raise Unexpected(
      token=parser.current.kind,
      expected="end of file after the root node",
      span=parser.current.span,
    )
  }
  { root, memreserves, is_plugin, }
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
  // slash itself, which the caller has already consumed for the root.
  // The root is written `/ { ... };`, so its name is the empty string and the
  // slash that introduces it is consumed here. Child nodes arrive with their
  // name already read from the body loop.
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
  self.expect_kind(LBrace, "'{' opening the node body")
  self.advance()
  let properties : Array[SourceProperty] = []
  let children : Array[SourceNode] = []
  let node_labels : Array[String] = []
  while !self.at_eof() {
    if same_kind(self.current.kind, RBrace) {
      self.advance()
      // A node definition ends with `};`. The semicolon is required by dtc and
      // its absence is the most common syntax error in hand-written sources,
      // so it is reported by name rather than as a brace mismatch.
      self.expect_kind(Semicolon, "';' after '}'")
      self.advance()
      return {
        name: node_name,
        labels: node_labels.copy(),
        properties,
        children,
      }
    }
    if same_kind(self.current.kind, Slash) {
      // A directive inside a node body.
      let directive = self.directive_word()
      match directive {
        Some(w) => {
          if w == "delete-node" ||
            w == "delete-property" ||
            w == "omit-if-no-ref" {
            raise Unsupported(
              what="\{w} inside a node body",
              span=self.current.span,
            )
          }
          raise Unexpected(
            token=self.current.kind,
            expected="a node, a property, or a directive this version understands",
            span=self.current.span,
          )
        }
        None =>
          raise Unexpected(
            token=self.current.kind,
            expected="a node or a property",
            span=self.current.span,
          )
      }
    }
    let (ident, ident_span) = self.take_ident("a node or property name")
    // A colon after an identifier binds it as a label for the node that
    // follows. This is the only place labels are recorded, and they stay in
    // source order so that phandle assignment is reproducible.
    if same_kind(self.current.kind, Colon) {
      self.advance()
      node_labels.push(ident)
      ignore(ident_span)
      continue
    }
    if same_kind(self.current.kind, Equals) ||
      same_kind(self.current.kind, Semicolon) {
      let prop = self.parse_property(ident, ident_span)
      properties.push(prop)
      continue
    }
    if same_kind(self.current.kind, LBrace) {
      // Labels accumulated before the node name belong to this node. They are
      // attached after parsing so the node is built in one place.
      let child = self.parse_node(ident)
      children.push({ ..child, labels: node_labels.copy(), })
      node_labels.clear()
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
    Amp => self.parse_reference()
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
          return PathRef("/" + join_path(parts))
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
fn join_path(parts : Array[String]) -> String {
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
