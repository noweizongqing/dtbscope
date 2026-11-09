// Token scanning for the device tree source format.
//
// Kept apart from the token types so that the types can be read without the
// scanning rules in the way, and so that the parser only ever imports the
// token vocabulary.

///|
/// Every way the scanner can reject a source file.
///
/// These are syntax defects, distinct from `DtbError` which describes a damaged
/// binary blob. Keeping them separate means a caller can tell "the file I was
/// given is not valid DTS" from "the tree I was given is inconsistent".
pub(all) suberror LexerError {
  /// A character that cannot appear outside a string or comment.
  UnexpectedChar(char~ : Char, span~ : Span)
  /// A `/*` with no matching `*/`.
  UnterminatedComment(start~ : Span)
  /// A `"` with no closing quote on the same logical string.
  UnterminatedString(start~ : Span)
  /// A backslash inside a string followed by something with no meaning.
  BadEscape(char~ : Char, span~ : Span)
  /// A number literal that does not fit in 64 bits or has a bad digit.
  BadNumber(text~ : String, span~ : Span)
}

///|
/// Renders a scanner error with its position.
pub impl Show for LexerError with fn output(self, logger) {
  let text = match self {
    UnexpectedChar(char~, span~) => "\{span}: unexpected character '\{char}'"
    UnterminatedComment(start~) => "\{start}: unterminated block comment"
    UnterminatedString(start~) => "\{start}: unterminated string"
    BadEscape(char~, span~) => "\{span}: unknown escape '\\\{char}'"
    BadNumber(text~, span~) => "\{span}: bad number '\{text}'"
  }
  logger.write_string(text)
}

///|
/// Exposes the scanner error message as a plain method.
pub extend LexerError with Show::{to_string, output}

///|
/// Whether `c` can start an identifier.
///
/// DTS identifiers cover node and property names, which include `#`, `-`, `.`
/// and `,` — `#address-cells`, `enable-method`, `arm,cortex-a72`. The first
/// character is restricted so that a stray `,` or `-` still tokenizes as
/// punctuation, which is what the parser needs in `reg = <0 1>, <2 3>`.
fn starts_ident(c : Char) -> Bool {
  let code = c.to_int()
  let lower = code >= 0x61 && code <= 0x7A
  let upper = code >= 0x41 && code <= 0x5A
  let digit = code >= 0x30 && code <= 0x39
  lower || upper || digit || c == '_' || c == '#' || c == '.'
}

///|
/// Whether `c` can continue an identifier once it has started.
fn continues_ident(c : Char) -> Bool {
  starts_ident(c) || c == '-' || c == ',' || c == '@' || c == '+' || c == '?'
}

///|
/// Whether `c` is a hex digit.
fn is_hex(c : Char) -> Bool {
  let code = c.to_int()
  let digit = code >= 0x30 && code <= 0x39
  let low = code >= 0x61 && code <= 0x66
  let high = code >= 0x41 && code <= 0x46
  digit || low || high
}

///|
/// Value of a hex digit, or -1 if it is not one.
fn hex_value(c : Char) -> Int32 {
  let code = c.to_int()
  if code >= 0x30 && code <= 0x39 {
    code - 0x30
  } else if code >= 0x61 && code <= 0x66 {
    code - 0x61 + 10
  } else if code >= 0x41 && code <= 0x46 {
    code - 0x41 + 10
  } else {
    -1
  }
}

///|
/// Scans the next token, skipping whitespace and comments first.
pub fn Lexer::next(self : Lexer) -> Token raise LexerError {
  self.skip_trivia()
  let span = self.span()
  if self.at_end() {
    return { kind: Eof, span, }
  }
  let c = self.peek(0)
  // Directives such as `/dts-v1/` are not a token of their own: the grammar
  // that needs them reads a Slash, the word, and the closing Slash. Keeping
  // them out of the token set means the parser decides what a leading slash
  // means by looking at what follows it, which is exactly what it has to do
  // for `/delete-node/` and `/omit-if-no-ref/` as well.
  let punctuation = match c {
    '{' => Some(LBrace)
    '}' => Some(RBrace)
    '<' => Some(LAngle)
    '>' => Some(RAngle)
    '[' => Some(LBracket)
    ']' => Some(RBracket)
    '(' => Some(LParen)
    ')' => Some(RParen)
    ',' => Some(Comma)
    ';' => Some(Semicolon)
    '=' => Some(Equals)
    '/' => Some(Slash)
    '&' => Some(Amp)
    ':' => Some(Colon)
    '-' => Some(Minus)
    _ => None
  }
  match punctuation {
    Some(kind) => {
      self.bump()
      // Bracket state is tracked here rather than in the parser so that the
      // number rule below can see it.
      if same_punct(kind, LBracket) {
        self.in_bytes = true
      } else if same_punct(kind, RBracket) {
        self.in_bytes = false
      }
      { kind, span, }
    }
    None =>
      if c == '"' {
        let kind = self.scan_string(span)
        { kind, span, }
      } else if self.in_bytes && is_hex(c) {
        let kind = self.scan_hex_byte(span)
        { kind, span, }
      } else if self.in_bytes && starts_ident(c) && self.is_hex_run() {
        let kind = self.scan_hex_byte(span)
        { kind, span, }
      } else if c >= '0' && c <= '9' {
        let kind = self.scan_number(span)
        { kind, span, }
      } else if starts_ident(c) {
        let kind = self.scan_ident()
        { kind, span, }
      } else {
        raise UnexpectedChar(char=c, span~)
      }
  }
}

///|
/// Compares punctuation kinds, which carry no payload.
fn same_punct(a : TokenKind, b : TokenKind) -> Bool {
  match (a, b) {
    (LBracket, LBracket) => true
    (RBracket, RBracket) => true
    _ => false
  }
}

///|
/// Whether the next run is a pair of hex digits, which the identifier rule
/// would otherwise claim as a name.
fn Lexer::is_hex_run(self : Lexer) -> Bool {
  let first = is_hex(self.peek(0))
  let second = is_hex(self.peek(1))
  let third = is_hex(self.peek(2))
  let fourth = is_hex(self.peek(3))
  first && second && !(third && fourth)
}

///|
/// Scans one byte inside a `[...]` string.
///
/// Bytes are exactly two hex digits. Older dtc accepted a single digit and
/// padded it, which made `[1 2]` mean `[01 02]`; current dtc rejects it, and
/// so does this scanner, because silently changing the byte count of a value
/// is the kind of difference that shows up much later as a wrong MAC address.
pub fn Lexer::scan_hex_byte(
  self : Lexer,
  span : Span,
) -> TokenKind raise LexerError {
  if !is_hex(self.peek(0)) || !is_hex(self.peek(1)) {
    raise BadNumber(text=self.peek(0).to_string(), span~)
  }
  let value = hex_value(self.peek(0)) * 16 + hex_value(self.peek(1))
  self.bump()
  self.bump()
  HexByte(value.to_byte())
}

///|
/// Scans an identifier: everything `continues_ident` accepts.
fn Lexer::scan_ident(self : Lexer) -> TokenKind {
  let buf = StringBuilder()
  while !self.at_end() && continues_ident(self.peek(0)) {
    buf.write_char(self.peek(0))
    self.bump()
  }
  Ident(buf.to_string())
}

///|
/// Scans an integer literal.
///
/// `0x` introduces hex; a trailing `U` or `L` is accepted and ignored, because
/// real DTS files contain `<0x1U>` and rejecting them would be gratuitous. The
/// value is accumulated in `UInt64` so that a full-width cell such as
/// `0xffffffff` round-trips without a sign.
fn Lexer::scan_number(self : Lexer, span : Span) -> TokenKind raise LexerError {
  let buf = StringBuilder()
  let hex = self.peek(0) == '0' && (self.peek(1) == 'x' || self.peek(1) == 'X')
  let mut value : UInt64 = 0UL
  if hex {
    buf.write_char(self.peek(0))
    buf.write_char(self.peek(1))
    self.bump()
    self.bump()
    let mut digits = 0
    while !self.at_end() && is_hex(self.peek(0)) {
      let d = hex_value(self.peek(0))
      // A literal wider than 64 bits cannot be a cell or an address, and
      // silently truncating it would be worse than rejecting it.
      if value > (0xFFFF_FFFF_FFFF_FFFFUL - d.to_uint64()) / 16UL {
        raise BadNumber(text=buf.to_string(), span~)
      }
      value = value * 16UL + d.to_uint64()
      buf.write_char(self.peek(0))
      self.bump()
      digits = digits + 1
    }
    if digits == 0 {
      raise BadNumber(text=buf.to_string(), span~)
    }
  } else {
    while !self.at_end() && self.peek(0) >= '0' && self.peek(0) <= '9' {
      let d = self.peek(0).to_int() - 0x30
      if value > (0xFFFF_FFFF_FFFF_FFFFUL - d.to_uint64()) / 10UL {
        raise BadNumber(text=buf.to_string(), span~)
      }
      value = value * 10UL + d.to_uint64()
      buf.write_char(self.peek(0))
      self.bump()
    }
  }
  // Size suffixes are legal on any literal; they carry no information the
  // binary form keeps, so they are consumed and dropped.
  while !self.at_end() && is_size_suffix(self.peek(0)) {
    self.bump()
  }
  Number(value)
}

///|
/// Whether `c` is one of the integer size suffixes the format tolerates.
///
/// `<0x10U>` and `<0x10UL>` appear in real sources; the suffix carries no
/// information the binary form keeps, so it is consumed and dropped.
fn is_size_suffix(c : Char) -> Bool {
  c == 'U' || c == 'u' || c == 'L' || c == 'l'
}

///|
/// Scans a double-quoted string, resolving escapes.
///
/// DTS strings are byte strings in the C sense: the only escapes the format
/// itself gives meaning to are `\"`, `\\` and the octal/hex forms that a C
/// preprocessor would have expanded before dtc ever sees the file. The common
/// ones here are the C set, and an unknown escape is an error rather than a
/// literal backslash, because a silently swallowed `\q` hides a typo.
fn Lexer::scan_string(self : Lexer, start : Span) -> TokenKind raise LexerError {
  let buf = StringBuilder()
  self.bump()
  while true {
    if self.at_end() {
      raise UnterminatedString(start~)
    }
    let c = self.peek(0)
    if c == '"' {
      self.bump()
      return String(buf.to_string())
    }
    if c == '\n' {
      // A raw newline inside a string is almost always an unterminated string
      // one line up. dtc accepts it, but the resulting message is much worse,
      // so it is refused here and the position points at the opening quote.
      raise UnterminatedString(start~)
    }
    if c == '\\' {
      let escape_span = self.span()
      self.bump()
      if self.at_end() {
        raise UnterminatedString(start~)
      }
      let e = self.peek(0)
      let decoded = match e {
        'n' => Some(0x0A)
        't' => Some(0x09)
        'r' => Some(0x0D)
        '0' => Some(0x00)
        'a' => Some(0x07)
        'b' => Some(0x08)
        'f' => Some(0x0C)
        'v' => Some(0x0B)
        '\\' => Some(0x5C)
        '"' => Some(0x22)
        '\'' => Some(0x27)
        'x' => {
          self.bump()
          let mut n = 0
          let mut count = 0
          while count < 2 && !self.at_end() && is_hex(self.peek(0)) {
            n = n * 16 + hex_value(self.peek(0))
            self.bump()
            count = count + 1
          }
          if count == 0 {
            raise BadEscape(char='x', span=escape_span)
          }
          Some(n)
        }
        _ => None
      }
      match decoded {
        Some(code) => {
          buf.write_char(code.unsafe_to_char())
          if e != 'x' {
            self.bump()
          }
        }
        None => raise BadEscape(char=e, span=escape_span)
      }
    } else {
      buf.write_char(c)
      self.bump()
    }
  }
  // Every branch inside the loop returns or raises, so the only way to reach
  // this point is a compiler bug; returning an empty string keeps the type
  // checker happy without pretending the case is reachable.
  String("")
}
