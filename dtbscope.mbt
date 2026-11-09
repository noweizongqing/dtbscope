// dtbscope — device tree compiler and inspector in pure MoonBit.
//
// This file holds the vocabulary shared by every parser in the module: the
// error type and the byte-order cursor. Keep it free of format-specific rules
// so that the DTS front end and the DTB back end can both depend on it.

///|
/// Every way a device tree blob can be rejected.
///
/// Parsing never returns a half-built tree. A damaged blob surfaces as one of
/// these, and the payload carries the offset of the bytes that failed so a
/// caller can point at them instead of guessing.
pub(all) suberror DtbError {
  /// The buffer ended before a structure could be read completely.
  UnexpectedEnd(offset~ : Int64, needed~ : Int64, available~ : Int64)
  /// The magic number is not 0xd00dfeed.
  BadMagic(magic~ : UInt32)
  /// A field holds a value the specification does not allow.
  BadValue(field~ : String, value~ : Int64)
  /// A size or offset addresses bytes outside the blob.
  OutOfBounds(what~ : String, offset~ : Int64, size~ : Int64, limit~ : Int64)
  /// A name or string is not valid UTF-8.
  BadName(offset~ : Int64)
  /// Two structures are each well-formed but contradict one another.
  Inconsistent(what~ : String, detail~ : String)
  /// A nesting depth or node count exceeded the configured limit.
  LimitExceeded(what~ : String, limit~ : Int64)
  /// A code path this version does not implement was reached.
  Unsupported(what~ : String)
}

///|
/// Renders an error as one line naming the field and the offset.
///
/// The CLI prints this verbatim, so it has to identify a byte, not just say
/// "malformed file".
pub impl Show for DtbError with fn output(self, logger) {
  let text = match self {
    UnexpectedEnd(offset~, needed~, available~) =>
      "unexpected end at offset \{offset}: needed \{needed} bytes, \{available} available"
    BadMagic(magic~) => "not a device tree blob: magic \{hex32(magic)}"
    BadValue(field~, value~) => "bad value for \{field}: \{value}"
    OutOfBounds(what~, offset~, size~, limit~) =>
      "\{what} at offset \{offset}+\{size} exceeds limit \{limit}"
    BadName(offset~) => "invalid string at offset \{offset}"
    Inconsistent(what~, detail~) => "\{what} is inconsistent: \{detail}"
    LimitExceeded(what~, limit~) => "\{what} exceeds the limit of \{limit}"
    Unsupported(what~) => "unsupported: \{what}"
  }
  logger.write_string(text)
}

///|
/// Exposes the message as a plain method so callers can format it themselves.
pub extend DtbError with Show::{to_string, output}

///|
/// Byte order of a field.
///
/// The DTB format is big-endian throughout, but the DTS front end has to quote
/// `/bits/ 16` cell lists in the host's own order when it dumps them back out,
/// so the reader keeps the axis explicit rather than hard-coding it.
pub(all) enum Endian {
  Little
  Big
}

///|
/// A position in a buffer together with the byte order to decode it in.
pub(all) struct Cursor {
  /// Absolute byte offset of the next field.
  pos : Int64
  /// Byte order applied to multi-byte fields.
  endian : Endian
}

///|
/// Produces a cursor at `pos` reading little-endian fields.
pub fn Cursor::little(pos : Int64) -> Cursor {
  Cursor::{ pos, endian: Little, }
}

///|
/// Produces a cursor at `pos` reading big-endian fields, which is what every
/// field inside a DTB uses.
pub fn Cursor::big(pos : Int64) -> Cursor {
  Cursor::{ pos, endian: Big, }
}

///|
/// Formats a 32-bit value as `0x` followed by just enough hex digits.
///
/// Used in error messages where the reader is comparing against a hex dump, so
/// leading zeroes are dropped but the prefix is always present.
fn hex32(v : UInt32) -> String {
  let digits = "0123456789abcdef"
  let raw = v.reinterpret_as_int()
  let buf = StringBuilder()
  buf.write_string("0x")
  let mut started = false
  for i in 0..<8 {
    let index = (raw >> ((7 - i) * 4)) & 0xF
    if index != 0 || started || i == 7 {
      started = true
      buf.write_char(digits.get_char(index).unwrap())
    }
  }
  buf.to_string()
}
