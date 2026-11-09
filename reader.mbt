// Bounds-checked reading of primitive values.
//
// Every function takes a cursor and returns the decoded value plus the
// advanced cursor, so a caller cannot observe a half-consumed field. Nothing
// here indexes a buffer without going through `Bounds::require` first: a
// truncated or corrupt blob has to come back as `UnexpectedEnd` or
// `OutOfBounds`, never as a wild read.

///|
/// Reinterprets the low 32 bits of an `Int64` as an unsigned word.
///
/// Values are accumulated in `Int64` so the high bit never turns the number
/// negative mid-calculation; this masks the truncation back down.
fn u32_of_int64(v : Int64) -> UInt32 {
  (v & 0xFFFF_FFFFL).to_int().reinterpret_as_uint()
}

///|
/// A buffer together with the range of it that may be read.
///
/// `start` and `limit` are absolute offsets into `bytes`. Keeping them
/// absolute means a sub-blob (the struct block inside a larger blob, say) can
/// be described without copying, while error messages still report a position
/// the caller can find in the original file.
pub(all) struct Bounds {
  /// Bytes of the blob.
  bytes : Bytes
  /// First readable offset.
  start : Int64
  /// One past the last readable offset.
  limit : Int64
}

///|
/// Wraps a whole buffer as readable from 0 to its length.
pub fn Bounds::of_bytes(bytes : Bytes) -> Bounds {
  Bounds::{ bytes, start: 0L, limit: bytes.length().to_int64(), }
}

///|
/// Restricts a buffer to `[start, limit)`, rejecting a range that runs off the
/// end of the underlying bytes.
pub fn Bounds::of_range(
  bytes : Bytes,
  start : Int64,
  limit : Int64,
) -> Bounds raise DtbError {
  let total = bytes.length().to_int64()
  if start < 0L || limit < start || limit > total {
    raise OutOfBounds(
      what="sub-range",
      offset=start,
      size=limit - start,
      limit=total,
    )
  }
  Bounds::{ bytes, start, limit, }
}

///|
/// Number of readable bytes.
pub fn Bounds::length(self : Bounds) -> Int64 {
  self.limit - self.start
}

///|
/// Fails unless `[offset, offset + size)` lies inside the readable range.
///
/// Parsers call this before trusting any length field that came out of the
/// file, so a corrupt length is reported with the field name that carried it.
pub fn Bounds::require(
  self : Bounds,
  offset : Int64,
  size : Int64,
  what : String,
) -> Unit raise DtbError {
  if size < 0L {
    raise OutOfBounds(what~, offset~, size~, limit=self.limit)
  }
  if offset < self.start || offset > self.limit || size > self.limit - offset {
    raise OutOfBounds(what~, offset~, size~, limit=self.limit)
  }
}

///|
/// Returns the byte at an absolute offset, after checking that it is readable.
fn Bounds::byte(self : Bounds, offset : Int64) -> Byte raise DtbError {
  self.require(offset, 1L, "byte")
  self.bytes.at(offset.to_int())
}

///|
/// Decodes an unsigned 8-bit integer.
pub fn Bounds::read_u8(
  self : Bounds,
  cur : Cursor,
) -> (UInt32, Cursor) raise DtbError {
  let v = self.byte(cur.pos).to_int().reinterpret_as_uint()
  (v, Cursor::{ pos: cur.pos + 1L, endian: cur.endian, })
}

///|
/// Decodes an unsigned 16-bit integer in the cursor's byte order.
pub fn Bounds::read_u16(
  self : Bounds,
  cur : Cursor,
) -> (UInt32, Cursor) raise DtbError {
  self.require(cur.pos, 2L, "u16")
  let base = cur.pos.to_int()
  let b0 = self.bytes.at(base).to_int().to_int64()
  let b1 = self.bytes.at(base + 1).to_int().to_int64()
  let v = match cur.endian {
    Little => b0 | (b1 << 8)
    Big => (b0 << 8) | b1
  }
  (u32_of_int64(v), Cursor::{ pos: cur.pos + 2L, endian: cur.endian, })
}

///|
/// Decodes an unsigned 32-bit integer in the cursor's byte order.
///
/// Accumulated in `Int64` so that a value with bit 31 set does not go negative
/// before it is reinterpreted.
pub fn Bounds::read_u32(
  self : Bounds,
  cur : Cursor,
) -> (UInt32, Cursor) raise DtbError {
  self.require(cur.pos, 4L, "u32")
  let base = cur.pos.to_int()
  let b0 = self.bytes.at(base).to_int().to_int64()
  let b1 = self.bytes.at(base + 1).to_int().to_int64()
  let b2 = self.bytes.at(base + 2).to_int().to_int64()
  let b3 = self.bytes.at(base + 3).to_int().to_int64()
  let v = match cur.endian {
    Little => b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    Big => (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
  }
  (u32_of_int64(v), Cursor::{ pos: cur.pos + 4L, endian: cur.endian, })
}

///|
/// Decodes an unsigned 64-bit integer in the cursor's byte order.
///
/// Returned as `Int64` so all 64 bits survive; callers that need the unsigned
/// reading mask at the use site, which is exactly where they have to think
/// about it anyway.
pub fn Bounds::read_u64(
  self : Bounds,
  cur : Cursor,
) -> (Int64, Cursor) raise DtbError {
  self.require(cur.pos, 8L, "u64")
  let (a, next) = self.read_u32(cur)
  let (b, next) = self.read_u32(next)
  let (hi, lo) = match cur.endian {
    Little => (b, a)
    Big => (a, b)
  }
  ((hi.to_int64() << 32) | (lo.to_int64() & 0xFFFF_FFFFL), next)
}

///|
/// Copies `n` bytes starting at `offset` into a fresh buffer.
pub fn Bounds::slice(
  self : Bounds,
  offset : Int64,
  n : Int64,
  what : String,
) -> Bytes raise DtbError {
  self.require(offset, n, what)
  let out = Buffer::Buffer(size_hint=n.to_int())
  for i in 0..<n.to_int() {
    out.write_byte(self.bytes.at(offset.to_int() + i))
  }
  out.to_bytes()
}

///|
/// Reads a NUL-terminated string that must end inside `[offset, limit)`.
///
/// Returns the string and the offset just past its terminator. The DTB strings
/// block holds all property names back to back, so the tail version is what the
/// caller actually needs.
pub fn Bounds::cstr(
  self : Bounds,
  offset : Int64,
  limit : Int64,
) -> (String, Int64) raise DtbError {
  if limit > self.limit {
    raise OutOfBounds(
      what="string",
      offset~,
      size=limit - offset,
      limit=self.limit,
    )
  }
  let start = offset.to_int()
  let mut end = start
  let stop = limit.to_int()
  while end < stop && self.bytes.at(end).to_int() != 0 {
    end = end + 1
  }
  if end >= stop {
    raise UnexpectedEnd(
      offset~,
      needed=(end - start + 1).to_int64(),
      available=(stop - start).to_int64(),
    )
  }
  let out = Buffer::Buffer(size_hint=end - start)
  for i in start..<end {
    out.write_byte(self.bytes.at(i))
  }
  let text = @utf8.decode(out.to_bytes()) catch { _ => raise BadName(offset~) }
  (text, (end + 1).to_int64())
}
