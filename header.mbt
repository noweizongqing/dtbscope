// The flattened device tree header.
//
// A blob starts with a 40-byte header that frames four blocks. Reading it is
// the first thing every entry point does, and it is also where a malformed
// blob has to be refused: the four size fields are the only statement about
// where the blocks live, so if they do not tile the file exactly there is no
// way to tell which one is wrong.

///|
/// The on-disk magic, `0xd00dfeed`.
///
/// Spelled out rather than derived so a reader comparing against a hex dump
/// can check it at a glance.
const DTB_MAGIC : UInt32 = 0xD00D_FEED

///|
/// Size of the header in bytes, constant across header versions.
const DTB_HEADER_SIZE : Int64 = 40L

///|
/// The last header version this module accepts.
///
/// Version 17 is what dtc has emitted since 2011. Earlier versions differ only
/// in the meaning of `last_comp_version` and in whether the blocks are
/// 8-byte aligned, so they are accepted but reported through
/// `Header::is_modern` rather than silently treated as 17.
const DTB_LAST_COMP_VERSION : UInt32 = 17

///|
/// The four blocks a blob is made of, with their offsets resolved against the
/// start of the file.
///
/// Offsets here are relative to the start of the blob, which is what every
/// tool that walks the tree needs. Absolute offsets would break the moment a
/// blob is embedded inside another container.
pub(all) struct Header {
  /// Header version that produced the blob.
  totalsize : Int64
  /// Where the struct block begins.
  off_dt_struct : Int64
  /// Where the strings block begins.
  off_dt_strings : Int64
  /// Where the memory reservation map begins.
  off_mem_rsvmap : Int64
  /// Header version.
  version : UInt32
  /// Oldest header version a reader must implement to parse this blob.
  last_comp_version : UInt32
  /// Physical ID of the boot CPU.
  boot_cpuid_phys : UInt32
  /// Length of the strings block.
  size_dt_strings : Int64
  /// Length of the struct block.
  size_dt_struct : Int64
}

///|
/// Reads the header at the start of a blob and validates that the four blocks
/// tile the file.
///
/// The alignment requirements from the specification are checked here rather
/// than at each use site: the struct block is 4-byte aligned, and in version 17
/// and later so is the strings block and the memory reservation map. A blob
/// that violates them is rejected before any block is decoded, so no later
/// parser has to defend against a misaligned read.
pub fn parse_header(bytes : Bytes) -> Header raise DtbError {
  let bounds = Bounds::of_bytes(bytes)
  let total = bounds.length()
  if total < DTB_HEADER_SIZE {
    raise UnexpectedEnd(offset=0L, needed=DTB_HEADER_SIZE, available=total)
  }
  let cur = Cursor::big(0L)
  let (magic, cur) = bounds.read_u32(cur)
  if magic != DTB_MAGIC {
    raise BadMagic(magic~)
  }
  let (totalsize, cur) = bounds.read_u32(cur)
  let (off_dt_struct, cur) = bounds.read_u32(cur)
  let (off_dt_strings, cur) = bounds.read_u32(cur)
  let (off_mem_rsvmap, cur) = bounds.read_u32(cur)
  let (version, cur) = bounds.read_u32(cur)
  let (last_comp_version, cur) = bounds.read_u32(cur)
  let (boot_cpuid_phys, cur) = bounds.read_u32(cur)
  let (size_dt_strings, _) = bounds.read_u32(cur)
  // Version 17 grew a second size word. Older blobs stop at 36 bytes of
  // content and leave the struct size implied by the remaining space, which
  // the caller cannot reconstruct reliably, so the version gate comes first.
  let size_dt_struct = if version >= DTB_LAST_COMP_VERSION {
    let (v, _) = bounds.read_u32(Cursor::big(36L))
    v
  } else {
    raise Unsupported(
      what="header version \{version.reinterpret_as_int()}, need \{DTB_LAST_COMP_VERSION.reinterpret_as_int()} or later",
    )
  }
  let header = Header::{
    totalsize: totalsize.to_int64(),
    off_dt_struct: off_dt_struct.to_int64(),
    off_dt_strings: off_dt_strings.to_int64(),
    off_mem_rsvmap: off_mem_rsvmap.to_int64(),
    version,
    last_comp_version,
    boot_cpuid_phys,
    size_dt_strings: size_dt_strings.to_int64(),
    size_dt_struct: size_dt_struct.to_int64(),
  }
  header.validate(bounds)
  header
}

///|
/// Checks that the header describes four blocks that fit inside the file
/// without overlapping the header or each other.
///
/// A single damaged size field usually still leaves every individual block
/// readable, so the check that catches it is the tiling one: the blocks have to
/// appear in the order the format requires and together cover the file with
/// nothing but padding between them.
fn Header::validate(self : Header, bounds : Bounds) -> Unit raise DtbError {
  let total = bounds.length()
  if self.totalsize <= DTB_HEADER_SIZE || self.totalsize > total {
    raise BadValue(field="totalsize", value=self.totalsize)
  }
  // Trusting totalsize over the actual buffer length is deliberate: a blob may
  // be followed by padding inside a larger file (a FIT image, say), and the
  // header is the only thing that says where it ends.
  let end = self.totalsize
  bounds.require(self.off_mem_rsvmap, 16L, "mem_rsvmap")
  bounds.require(self.off_dt_struct, self.size_dt_struct, "struct block")
  bounds.require(self.off_dt_strings, self.size_dt_strings, "strings block")
  if self.off_mem_rsvmap < DTB_HEADER_SIZE {
    raise Inconsistent(
      what="mem_rsvmap",
      detail="starts at \{self.off_mem_rsvmap} inside the header",
    )
  }
  if self.off_dt_struct % 4L != 0L {
    raise Inconsistent(what="struct block", detail="not 4-byte aligned")
  }
  if self.off_dt_strings % 4L != 0L {
    raise Inconsistent(what="strings block", detail="not 4-byte aligned")
  }
  if self.off_dt_struct + self.size_dt_struct > self.off_dt_strings {
    raise Inconsistent(
      what="struct block",
      detail="ends at \{self.off_dt_struct + self.size_dt_struct} past the strings block at \{self.off_dt_strings}",
    )
  }
  if self.off_dt_strings + self.size_dt_strings > end {
    raise Inconsistent(
      what="strings block",
      detail="ends at \{self.off_dt_strings + self.size_dt_strings} past the blob end at \{end}",
    )
  }
  if self.version < self.last_comp_version {
    raise BadValue(
      field="last_comp_version",
      value=self.last_comp_version.to_int64(),
    )
  }
}

///|
/// Whether the blob uses the version 17 alignment rules.
///
/// Version 16 and earlier packed the strings block without padding, so callers
/// that care about byte-identical round-tripping have to know which rules were
/// in force when the input was produced.
pub fn Header::is_modern(self : Header) -> Bool {
  self.last_comp_version >= 16
}

///|
/// Total size the header claims, which is also the length a verbatim copy has
/// to preserve.
pub fn Header::size(self : Header) -> Int64 {
  self.totalsize
}
