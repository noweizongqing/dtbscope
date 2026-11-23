// `/include/` expansion.
//
// dtc's `/include/ "file"` is a textual include performed by the lexer, not by
// cpp: it pastes the file's tokens in place and carries on. That distinction is
// what makes it this project's job rather than the preprocessor's, and it is
// why a source that uses it can be compiled here without a C toolchain.
//
// The expansion happens on text before scanning. Doing it at the token level
// would be more faithful to how dtc does it, but the include directive is
// line-oriented in practice — it stands alone on its own line — and a text
// splice reproduces dtc's behaviour for every form the specification shows.
// A `/include/` that is not alone on its line is refused rather than guessed
// at, because pasting a fragment into the middle of an expression would need
// the lexer to resume mid-token.

///|
/// An error from include expansion.
pub suberror IncludeError {
  /// The named file could not be read.
  Unreadable(path~ : String, detail~ : String)
  /// An include cycle, which would expand forever.
  Cycle(path~ : String, chain~ : Array[String])
  /// The directive was not on a line of its own.
  Misplaced(line~ : Int32)
  /// Nesting deeper than the limit, which is a cycle the path check missed or
  /// a generated file that is simply too deep.
  TooDeep(limit~ : Int32)
}

///|
/// Renders an include error.
pub impl Show for IncludeError with fn output(self, logger) {
  let text = match self {
    Unreadable(path~, detail~) => "cannot read include '\{path}': \{detail}"
    Cycle(path~, chain~) => {
      let joined = join_chain(chain, " -> ")
      "include cycle: \{joined} -> \{path}"
    }
    Misplaced(line~) => "line \{line}: /include/ has to be alone on its line"
    TooDeep(limit~) => "includes nested deeper than \{limit}"
  }
  logger.write_string(text)
}

///|
/// Exposes the text as a plain method.
pub extend IncludeError with Show::{to_string, output}

///|
/// How deep includes may nest.
///
/// The DTS specification says nothing about a limit; this one exists so that a
/// file that includes itself through a path the cycle check cannot see — a
/// symlink, say — fails instead of exhausting memory.
const MAX_INCLUDE_DEPTH : Int32 = 32

///|
/// Reads a source and replaces every `/include/ "file"` with that file's text.
///
/// `read` is the caller's file reader, so the same expansion works against a
/// filesystem in the CLI and against a map in a test or a browser. Paths are
/// resolved relative to the including file, which is what dtc does and what
/// makes an include work regardless of the process's working directory.
pub fn expand_includes(
  text : String,
  origin : String,
  read : (String) -> Result[String, String],
) -> String raise IncludeError {
  let chain : Array[String] = []
  expand(text, origin, read, chain, 0)
}

///|
/// One level of expansion.
fn expand(
  text : String,
  origin : String,
  read : (String) -> Result[String, String],
  chain : Array[String],
  depth : Int32,
) -> String raise IncludeError {
  if depth > MAX_INCLUDE_DEPTH {
    raise TooDeep(limit=MAX_INCLUDE_DEPTH)
  }
  for entry in chain {
    if entry == origin {
      raise Cycle(path=origin, chain~)
    }
  }
  chain.push(origin)
  let out = StringBuilder()
  let lines = split_on_newlines(text)
  let mut line_number = 1
  for line in lines {
    // A line that starts with the directive but does not consist of it is a
    // misplacement: pasting a fragment mid-line would need the lexer to resume
    // inside a token, which this expansion cannot represent.
    if starts_include(line) && include_target(line) is None {
      raise Misplaced(line=line_number)
    }
    match include_target(line) {
      None => out.write_string(line + "\n")
      // The included text takes the directive's place. A newline is written
      // after it so that a file not ending in one does not glue its last
      // line to whatever followed the include.
      Some(target) => {
        let path = resolve_relative(origin, target)
        let body = match read(path) {
          Ok(body) => body
          Err(detail) => raise Unreadable(path~, detail~)
        }
        let expanded = expand(body, path, read, chain, depth + 1)
        out.write_string(expanded)
        if !expanded.has_suffix("\n") {
          out.write_string("\n")
        }
      }
    }
    line_number = line_number + 1
  }
  ignore(line_number)
  ignore(chain.pop())
  out.to_string()
}

///|
/// The line may be indented, and a trailing carriage return from a
/// CRLF-terminated file is dropped. Anything after the closing quote other than
/// whitespace means the directive is not alone on its line, which is refused
/// rather than merged.
fn starts_include(line : String) -> Bool {
  trim_ascii(line, both=true).has_prefix("/include/")
}

///|
/// Whether a line is a `/include/ "file"` directive, and what it names.
fn include_target(line : String) -> String? {
  let trimmed = trim_ascii(line, both=true)
  if !trimmed.has_prefix("/include/") {
    return None
  }
  let rest = trim_ascii(trimmed[9:].to_owned(), both=true)
  if !rest.has_prefix("\"") {
    return None
  }
  let close = find_char(rest, '"', 1)
  match close {
    None => None
    Some(i) => {
      let after = trim_ascii(rest[i + 1:].to_owned(), both=true)
      // Anything but whitespace after the quote means the include is not the
      // whole line. dtc requires it to be, and guessing at a mid-line paste
      // would produce a source that compiles differently here than there.
      if after.length() > 0 {
        return None
      }
      Some(rest[1:i].to_owned())
    }
  }
}

///|
/// Resolves an include path against the including file's directory.
///
/// An absolute path is used as written. A relative one is joined to the
/// directory of `origin`, so `include/board.dtsi` from `/src/a/b.dts` finds
/// `/src/a/include/board.dtsi` rather than depending on the working directory.
fn resolve_relative(origin : String, target : String) -> String {
  if target.has_prefix("/") {
    return target
  }
  let slash = last_char_index(origin, '/')
  match slash {
    None => target
    Some(i) => origin[:i].to_owned() + "/" + target
  }
}

///|
/// Index of the last occurrence of `c`, or None.
fn last_char_index(s : String, c : Char) -> Int32? {
  let mut found : Int32? = None
  for i in 0..<s.length() {
    if s.get_char(i).unwrap() == c {
      found = Some(i)
    }
  }
  found
}

///|
/// Index of the next occurrence of `c` at or after `from`.
fn find_char(s : String, c : Char, from : Int32) -> Int32? {
  let mut i = from
  while i < s.length() {
    if s.get_char(i).unwrap() == c {
      return Some(i)
    }
    i = i + 1
  }
  None
}

///|
/// Trims leading and trailing ASCII whitespace.
fn trim_ascii(s : String, both~ : Bool) -> String {
  let mut start = 0
  let mut end = s.length()
  if both {
    while start < end {
      let c = s.get_char(start).unwrap()
      if c == ' ' || c == '\t' || c == '\r' || c == '\n' {
        start = start + 1
      } else {
        break
      }
    }
  }
  while end > start {
    let c = s.get_char(end - 1).unwrap()
    if c == ' ' || c == '\t' || c == '\r' || c == '\n' {
      end = end - 1
    } else {
      break
    }
  }
  s[start:end].to_owned()
}

///|
/// Splits on newlines, dropping the newline characters.
///
/// A trailing newline produces no trailing empty entry, so joining the result
/// with `\n` restores the input minus that last newline — which the caller
/// then puts back.
fn split_on_newlines(text : String) -> Array[String] {
  let out : Array[String] = []
  let mut start = 0
  for i in 0..<text.length() {
    if text.get_char(i).unwrap() == '\n' {
      let line = text[start:i].to_owned()
      // A CRLF file leaves a `\r` that `include_target` trims, and writing it
      // back would change a file's line endings. It is dropped here instead.
      if line.has_suffix("\r") {
        out.push(line[:line.length() - 1].to_owned())
      } else {
        out.push(line)
      }
      start = i + 1
    }
  }
  if start < text.length() {
    out.push(text[start:].to_owned())
  }
  out
}

///|
/// Joins strings with a separator.
fn join_chain(parts : Array[String], sep : String) -> String {
  let buf = StringBuilder()
  let mut first = true
  for p in parts {
    if !first {
      buf.write_string(sep)
    }
    first = false
    buf.write_string(p)
  }
  buf.to_string()
}
