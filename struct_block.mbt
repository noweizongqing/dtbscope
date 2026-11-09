// The struct block: a token stream that describes the node tree.
//
// Each token is a big-endian 32-bit tag, followed by payload whose shape
// depends on the tag. Property names are stored once in the strings block and
// referenced by offset, which is why the walk needs both blocks rather than
// just this one.
//
// The walk is iterative and carries an explicit stack. device trees in the
// wild reach 15-20 levels (a PCIe root complex under a bus under a soc node),
// and a recursive descent would put that depth on the call stack for no gain:
// the parser never needs to look at a parent before its children.

///|
/// Token tags that appear in the struct block.
///
/// `0x5` through `0x8` are unspecified and must be skipped by a reader, which
/// is why `parse_struct` treats an unknown tag as an error rather than trying
/// to guess a skip length: the format gives no way to know how long an unknown
/// token is.
pub(all) enum Token {
  /// `0x1`: a node named by the string that follows, 4-byte aligned.
  BeginNode
  /// `0x2`: the end of the innermost open node.
  EndNode
  /// `0x3`: a property: length, name offset, then value bytes.
  Prop
  /// `0x4`: padding, no payload.
  Nop
  /// `0x9`: the end of the struct block.
  End
}

///|
/// A property as it appears in the block: a name resolved through the strings
/// block and the value bytes exactly as stored.
///
/// The value is left as raw bytes rather than decoded into cells. A property
/// can be a string, a cell list, a byte string, or an interleaved list of
/// those, and which one it is depends on a binding rather than on the bytes.
/// Decoding here would mean guessing, so the caller decodes with the schema it
/// has.
pub(all) struct Property {
  /// Name, resolved through the strings block.
  name : String
  /// Value bytes, unpadded.
  value : Bytes
  /// Offset of the token in the blob, for error messages and diffing.
  offset : Int64
}

///|
/// One node of the tree.
///
/// The root node's name is the empty string, matching the `/` of the source
/// form. Property and child order is preserved as the blob lists them, because
/// `dtc` writes properties before children and byte-identical round-tripping
/// depends on keeping that order rather than sorting it.
pub(all) struct Node {
  /// The node name. The root node is the empty string.
  name : String
  /// Properties in the order the blob lists them.
  properties : Array[Property]
  /// Children in the order the blob lists them.
  children : Array[Node]
}

///|
/// A structural fact about the blob that a strict reader rejects but that
/// appears in firmware produced by older generators.
///
/// These are reported rather than raised: the tree is still readable, and a
/// tool that refused to show it would be less useful than one that shows it
/// with the defect named.
pub(all) enum Warning {
  /// The struct block ended without the final `END` token.
  MissingEnd(offset~ : Int64)
  /// The `END` token was followed by bytes that do not parse as tokens.
  TrailingData(offset~ : Int64, remaining~ : Int64)
}

///|
/// Renders a warning as one line, in the same shape as the errors.
pub impl Show for Warning with fn output(self, logger) {
  let text = match self {
    MissingEnd(offset~) =>
      "struct block ended at \{offset} without an END token"
    TrailingData(offset~, remaining~) =>
      "\{remaining} byte(s) after the END token at \{offset}"
  }
  logger.write_string(text)
}

///|
/// Exposes the warning message as a plain method.
pub extend Warning with Show::{to_string, output}

///|
/// The result of walking the struct block: the root node plus anything
/// noteworthy that did not justify failing the parse.
pub(all) struct Tree {
  /// The root node, named "".
  root : Node
  /// Structural defects that were tolerated.
  warnings : Array[Warning]
}

///|
/// Nesting limit. The deepest tree in the Linux kernel sources is 22 levels;
/// 64 leaves room for generated trees without letting a malicious or corrupt
/// blob drive the explicit stack to an unbounded size.
const MAX_DEPTH : Int32 = 64

///|
/// Reads the tag at `offset` without consuming a payload.
fn tag_at(bounds : Bounds, offset : Int64) -> Token raise DtbError {
  let (raw, _) = bounds.read_u32(Cursor::big(offset))
  match raw {
    0x1 => BeginNode
    0x2 => EndNode
    0x3 => Prop
    0x4 => Nop
    0x9 => End
    _ => raise BadValue(field="struct tag", value=raw.to_int64())
  }
}

///|
/// Walks the struct block and builds the node tree.
///
/// Every child node is appended to its parent as soon as its own `END_NODE`
/// is seen, so a partially built tree can never be observed by the caller: the
/// only way out is the completed `Tree` or an error.
pub fn parse_struct(
  struct_bounds : Bounds,
  strings_bounds : Bounds,
) -> Tree raise DtbError {
  let nodes = struct_bounds
  let strings = strings_bounds
  let warnings : Array[Warning] = []
  // The blob opens the root node with its own BEGIN_NODE, so the stack starts
  // empty and the root is whatever that first frame closes into. Seeding it
  // with an empty root instead would give the tree two roots, with every
  // property landing on the wrong one.
  let stack : Array[Node] = []
  let mut cur = Cursor::big(nodes.start)
  let mut finished : Node? = None
  while finished is None {
    if cur.pos + 4L > nodes.limit {
      warnings.push(MissingEnd(offset=cur.pos))
      break
    }
    let tag = tag_at(nodes, cur.pos)
    let token_offset = cur.pos
    match tag {
      BeginNode => {
        if stack.length() >= MAX_DEPTH {
          raise LimitExceeded(what="node nesting", limit=MAX_DEPTH.to_int64())
        }
        let (name, next) = nodes.cstr(cur.pos + 4L, nodes.limit)
        stack.push({ name, properties: [], children: [], })
        cur = Cursor::big(align4(next))
        ignore(token_offset)
      }
      EndNode => {
        if stack.length() == 0 {
          raise Inconsistent(
            what="END_NODE",
            detail="closes a node that was never opened",
          )
        }
        let closed = stack.pop().unwrap()
        cur = Cursor::big(cur.pos + 4L)
        if stack.length() == 0 {
          // The outermost node is the root; there is nothing to attach it to.
          finished = Some(closed)
        } else {
          stack[stack.length() - 1].children.push(closed)
        }
      }
      Prop => {
        if stack.length() == 0 {
          // A property outside any node has nowhere to live. dtc rejects such
          // a blob, and accepting it would mean inventing a parent.
          raise Inconsistent(
            what="PROP",
            detail="appears before any BEGIN_NODE",
          )
        }
        let (len_raw, after_len) = nodes.read_u32(Cursor::big(cur.pos + 4L))
        let (name_off, after_name) = nodes.read_u32(after_len)
        let length = len_raw.to_int64()
        let (name, _) = strings.cstr(
          strings_bounds.start + name_off.to_int64(),
          strings_bounds.limit,
        )
        // `length` is the real value length, not the padded one: a string
        // property such as "memory" is 7 bytes with its NUL and is followed by
        // one padding byte. Only the cursor is rounded up.
        let value = nodes.slice(after_name.pos, length, "property value")
        stack[stack.length() - 1].properties.push({
          name,
          value,
          offset: token_offset,
        })
        cur = Cursor::big(align4(after_name.pos + length))
      }
      Nop => cur = Cursor::big(cur.pos + 4L)
      End => {
        cur = Cursor::big(cur.pos + 4L)
        if stack.length() != 1 {
          raise Inconsistent(
            what="END",
            detail="\{stack.length()} node(s) still open",
          )
        }
        if cur.pos < nodes.limit {
          warnings.push(
            TrailingData(offset=cur.pos, remaining=nodes.limit - cur.pos),
          )
        }
        finished = Some(stack[0])
      }
    }
  }
  match finished {
    Some(root) => { root, warnings, }
    None =>
      // No END token was seen. If nothing is left open the tree above is
      // complete and the warning already pushed names the truncation; when
      // nodes are still open the blob is genuinely malformed, because there is
      // no way to know whether the missing levels had children.
      if stack.length() == 1 {
        { root: stack[0], warnings, }
      } else if stack.length() == 0 {
        raise Inconsistent(what="struct block", detail="contains no root node")
      } else {
        raise Inconsistent(
          what="struct block",
          detail="ended with \{stack.length()} node(s) open",
        )
      }
  }
}

///|
/// Rounds an offset up to the next multiple of 4.
///
/// Property values and node names are padded to a word boundary, and the
/// padding is not required to be zero, so the offset is advanced rather than
/// the bytes being inspected.
fn align4(offset : Int64) -> Int64 {
  (offset + 3L) / 4L * 4L
}
