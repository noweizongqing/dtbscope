// Lexical analysis of the device tree source format.
//
// The scanner produces tokens and records the line and column of each one, so
// a syntax error can point at a place in the file rather than at a byte
// offset. Byte offsets would be useless here: DTS is edited by hand and the
// reader is looking at a text editor, not a hex dump.
//
// The format has no string interpolation and no numeric literals with a sign,
// which keeps the scanner small. The one unusual rule is that a slash starts
// three different things: a node close `/`, a directive like `/dts-v1/`, and a
// comment `//` or `/*`, so the scanner looks ahead by one character in every
// case where a slash appears.

///|
/// A position in the source file, 1-based so that it matches what an editor
/// shows.
pub(all) struct Span {
  /// Line number, starting at 1.
  line : Int32
  /// Column number, starting at 1.
  column : Int32
}

///|
/// Renders a span the way a compiler does: `line:column`.
pub impl Show for Span with fn output(self, logger) {
  logger.write_string("\{self.line}:\{self.column}")
}

///|
/// Exposes the span text as a plain method.
pub extend Span with Show::{to_string, output}

///|
/// The kinds of token the source format needs.
///
/// A label appears before a node rather than inside the value grammar, so it
/// needs no separate token kind: the parser sees `Ident`, `Colon` and decides
/// from what follows.
pub(all) enum TokenKind {
  /// An identifier: a node name, a property name, a label, a directive word.
  Ident(String)
  /// A double-quoted string with escapes already resolved.
  String(String)
  /// An unsigned integer literal.
  Number(UInt64)
  /// `{`
  LBrace
  /// `}`
  RBrace
  /// `<`
  LAngle
  /// `>`
  RAngle
  /// `[`
  LBracket
  /// `]`
  RBracket
  /// `(`
  LParen
  /// `)`
  RParen
  /// `,`
  Comma
  /// `;`
  Semicolon
  /// `=`
  Equals
  /// `/`
  Slash
  /// `&`, which introduces a reference
  Amp
  /// `:` used to bind a label to a node
  Colon
  /// `-`, used by `/delete-property/` style directives and by `/omit-if-no-ref/`
  Minus
  /// A two-digit hex byte from inside a `[...]` byte string.
  ///
  /// The scanner cannot decide what a digit run means without knowing that it
  /// is inside brackets, so it tracks that state. Emitting bytes rather than
  /// numbers avoids re-splitting `11` back into digits at the parser, which is
  /// where the first version got `00 11` wrong: `00` folded to `0` and `11` to
  /// decimal eleven.
  HexByte(Byte)
  /// End of input
  Eof
}

///|
/// Renders a token for error messages: the kind, not the span.
pub impl Show for TokenKind with fn output(self, logger) {
  let text = match self {
    Ident(s) => "identifier '\{s}'"
    String(_) => "string"
    Number(n) => "number \{n}"
    LBrace => "'{'"
    RBrace => "'}'"
    LAngle => "'<'"
    RAngle => "'>'"
    LBracket => "'['"
    RBracket => "']'"
    LParen => "'('"
    RParen => "')'"
    Comma => "','"
    Semicolon => "';'"
    Equals => "'='"
    Slash => "'/'"
    Amp => "'&'"
    Colon => "':'"
    Minus => "'-'"
    HexByte(b) => "byte 0x\{b.to_int()}"
    Eof => "end of input"
  }
  logger.write_string(text)
}

///|
/// Exposes the token text as a plain method.
pub extend TokenKind with Show::{to_string, output}

///|
/// A token together with where it came from.
///
/// Declared after `TokenKind` because MoonBit resolves a struct's field types
/// at the point the struct is declared, and the scanner returns these by
/// value, so the order matters.
pub(all) struct Token {
  /// What the token is.
  kind : TokenKind
  /// Where it starts.
  span : Span
}

///|
/// The scanner state: the source text plus a position in it.
///
/// The position is a byte offset into the string together with the line and
/// column that offset sits at. Both are advanced together so that `Span` never
/// has to be recomputed by rescanning from the start of the file.
pub(all) struct Lexer {
  source : String
  mut pos : Int32
  mut line : Int32
  mut column : Int32
  /// Whether the scanner is inside a `[...]` byte string.
  ///
  /// A digit run means a byte there and a number everywhere else, and the two
  /// cannot be told apart after the fact: `00` as a number is zero, losing the
  /// digit count that makes it two hex digits. Tracking one bit here keeps the
  /// parser from having to reconstruct it.
  mut in_bytes : Bool
}

///|
/// Copies the scanner so a caller can look at the next token without
/// consuming it.
///
/// The alternative is a token buffer in the parser, which would mean every
/// directive check allocating. A clone is two integers and a string reference,
/// and the string is immutable, so this is the cheaper of the two.
pub fn Lexer::clone(self : Lexer) -> Lexer {
  Lexer::{
    source: self.source,
    pos: self.pos,
    line: self.line,
    column: self.column,
    in_bytes: self.in_bytes,
  }
}

///|
/// Creates a scanner at the first character of `source`.
pub fn Lexer::new(source : String) -> Lexer {
  Lexer::{ source, pos: 0, line: 1, column: 1, in_bytes: false, }
}

///|
/// Whether the scanner has reached the end.
pub fn Lexer::at_end(self : Lexer) -> Bool {
  self.pos >= self.source.length()
}

///|
/// Returns the character `ahead` places past the cursor without consuming it.
///
/// Used for the one-character lookahead that every slash and every number
/// needs. Returns NUL past the end so callers can compare without an option.
fn Lexer::peek(self : Lexer, ahead : Int32) -> Char {
  let at = self.pos + ahead
  if at >= self.source.length() {
    '\u{0}'
  } else {
    self.source.get_char(at).unwrap()
  }
}

///|
/// Consumes one character and keeps the line and column in step.
fn Lexer::bump(self : Lexer) -> Unit {
  if self.at_end() {
    return
  }
  if self.peek(0) == '\n' {
    self.line = self.line + 1
    self.column = 1
  } else {
    self.column = self.column + 1
  }
  self.pos = self.pos + 1
}

///|
/// Skips whitespace and comments. DTS has `//` line comments and `/* */`
/// block comments, the same set C has minus the preprocessor cases.
fn Lexer::skip_trivia(self : Lexer) -> Unit raise LexerError {
  while !self.at_end() {
    let c = self.peek(0)
    if c == ' ' || c == '\t' || c == '\r' || c == '\n' {
      self.bump()
    } else if c == '/' && self.peek(1) == '/' {
      while !self.at_end() && self.peek(0) != '\n' {
        self.bump()
      }
    } else if c == '/' && self.peek(1) == '*' {
      let start = self.span()
      self.bump()
      self.bump()
      let mut closed = false
      while !self.at_end() {
        if self.peek(0) == '*' && self.peek(1) == '/' {
          self.bump()
          self.bump()
          closed = true
          break
        }
        self.bump()
      }
      if !closed {
        raise UnterminatedComment(start~)
      }
    } else {
      return
    }
  }
}

///|
/// The current position as a span.
fn Lexer::span(self : Lexer) -> Span {
  Span::{ line: self.line, column: self.column, }
}
