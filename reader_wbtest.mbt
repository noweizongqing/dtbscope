// Bounds tests.
//
// Every read in the library funnels through `Bounds::require`, and the caller
// of the library is usually a loader handing it bytes off a boot partition. A
// blob that is one byte short, or whose header points a block past the end of
// the file, has to come back as an error rather than a read of whatever
// follows in memory. These cases are written against `Bounds` directly because
// that is where the check lives: a test that goes through `parse_header` shows
// the header path works, not that the primitive is right.

///|
/// A bounds over `n` counted bytes.
fn bounds_of(n : Int32) -> Bounds {
  let buf = Buffer()
  for i in 0..<n {
    buf.write_byte((i : Int32).to_byte())
  }
  Bounds::of_bytes(buf.to_bytes())
}

///|
/// Runs a read and reports either that it was accepted or the error text.
fn check(b : Bounds, offset : Int64, size : Int64, what : String) -> String {
  try {
    b.require(offset, size, what)
    "accepted"
  } catch {
    e => e.to_string()
  }
}

///|
/// The last byte of a buffer is readable and the position just past it is not.
///
/// This is the off-by-one a `size > limit` check gets wrong in the other
/// direction: written as `offset + size >= limit` it rejects a read that ends
/// exactly at the end, and every strings block does that on its last entry.
test "bounds: last byte in, one past out" {
  let b = bounds_of(4)
  inspect(check(b, 3L, 1L, "byte"), content="accepted")
  inspect(
    check(b, 4L, 1L, "byte"),
    content="byte at offset 4+1 exceeds limit 4",
  )
}

///|
/// A read that starts inside the buffer and runs past the end is rejected.
///
/// A check of `offset < limit` alone passes this case and reads past the end;
/// so does `offset + size <= limit` computed in 32 bits when the values are
/// large. Both the start and the span have to be compared.
test "bounds: spans past the end" {
  let b = bounds_of(8)
  inspect(check(b, 6L, 4L, "u32"), content="u32 at offset 6+4 exceeds limit 8")
}

///|
/// An offset below the block start is rejected even though it is inside the
/// underlying buffer.
///
/// A struct block described with `Bounds::of_range` has a `start` above zero,
/// and a string offset is relative to its block. An offset that reaches back
/// into the header is inside the file and outside the block; accepting it
/// would read a block's neighbour as though it belonged to it.
test "bounds: offset below the block start" {
  let whole = bounds_of(16)
  let b = Bounds::of_range(whole.bytes, 8L, 16L)
  inspect(check(b, 9L, 1L, "byte"), content="accepted")
  inspect(
    check(b, 0L, 1L, "byte"),
    content="byte at offset 0+1 exceeds limit 16",
  )
}

///|
/// A range that runs off the end of the buffer is rejected when it is built,
/// not when it is first read. A caller that never reads the block would
/// otherwise accept a header pointing anywhere.
test "bounds: sub-range past the end" {
  let whole = bounds_of(16)
  let out = try {
    let _ = Bounds::of_range(whole.bytes, 8L, 20L)
    "accepted"
  } catch {
    e => e.to_string()
  }
  inspect(out, content="sub-range at offset 8+12 exceeds limit 16")
}

///|
/// A negative size is rejected before the arithmetic.
///
/// Left to the span check, `limit - offset` with a negative size makes the
/// comparison pass, and the caller slices with a length that came from the
/// file and is about to be used as one.
test "bounds: negative size" {
  let b = bounds_of(8)
  inspect(
    check(b, 0L, -1L, "byte"),
    content="byte at offset 0+-1 exceeds limit 8",
  )
}

///|
/// A zero-length read is legal at the end of the block, and illegal past it.
///
/// A zero-length property value is legal, so `size` of zero has to be
/// accepted; it must not be accepted at an offset the block does not reach,
/// which would let a caller slice from beyond the end and get an empty result
/// where an error belongs.
test "bounds: zero length" {
  let b = bounds_of(4)
  inspect(check(b, 4L, 0L, "value"), content="accepted")
  inspect(
    check(b, 5L, 0L, "value"),
    content="value at offset 5+0 exceeds limit 4",
  )
}
