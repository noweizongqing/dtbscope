// dtbscope — command line front end.
//
// The CLI stays thin: it reads bytes or text, calls the library, and writes
// the result. Every rule about what a device tree may contain lives in the
// library package, so the same checks apply to a browser build that calls the
// library directly.

///|
/// What the command line asked for.
enum Mode {
  /// Decode a blob and print the tree.
  Dump(String)
  /// Decode a blob and print it as device tree source.
  Decompile(String)
  /// Compile a source file to a blob.
  Compile(input~ : String, output~ : String)
  /// Compile with `/plugin/` handling, producing a .dtbo.
  CompileOverlay(input~ : String, output~ : String)
  /// Apply an overlay to a base tree and write the merged blob.
  Apply(base~ : String, overlay~ : String, output~ : String)
  /// Print usage.
  Help
  /// Print the version.
  Version
}

///|
/// Parses arguments.
///
/// Hand-rolled rather than pulled from a library: the option set is four
/// flags, and a dependency for that would be larger than the CLI.
fn parse_args(args : Array[String]) -> Mode raise {
  let mut input : String? = None
  let mut output : String? = None
  let mut dump = false
  let mut plugin = false
  let mut decompile = false
  let mut base : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "-h" || arg == "--help" {
      return Help
    } else if arg == "-V" || arg == "--version" {
      return Version
    } else if arg == "-o" || arg == "--output" {
      i = i + 1
      if i >= args.length() {
        raise Failure("-o needs a path")
      }
      output = Some(args[i])
    } else if arg == "-d" || arg == "--dump" {
      dump = true
    } else if arg == "-D" || arg == "--decompile" {
      decompile = true
    } else if arg == "--plugin" {
      plugin = true
    } else if arg == "-b" || arg == "--base" {
      i = i + 1
      if i >= args.length() {
        raise Failure("-b needs a path")
      }
      base = Some(args[i])
    } else if arg.has_prefix("-") && arg != "-" {
      raise Failure("unknown option \{arg}")
    } else if input is None {
      input = Some(arg)
    } else {
      raise Failure("more than one input file")
    }
    i = i + 1
  }
  match input {
    None => raise Failure("no input file")
    Some(path) =>
      if dump {
        Dump(path)
      } else if decompile {
        Decompile(path)
      } else {
        match (output, base) {
          (Some(out), Some(base_path)) =>
            Apply(base=base_path, overlay=path, output=out)
          (Some(out), None) =>
            if plugin {
              CompileOverlay(input=path, output=out)
            } else {
              Compile(input=path, output=out)
            }
          (None, _) =>
            raise Failure("compiling needs -o <path>; use -d to dump instead")
        }
      }
  }
}

///|
/// Runs the requested mode and reports the error, if any, on stderr.
fn main {
  let args = @env.args()
  // The first element is the program name on native and on wasm-gc, but the
  // JavaScript backend hands over only the arguments `moon run` passed. A
  // fixed offset would drop the input file there and read the program path
  // into the argument list here, so the drop happens only when the first
  // element actually looks like the program name.
  // The JavaScript backend runs under `node`, so the leading entries are the
  // interpreter and the script before any argument appears. Native and wasm-gc
  // have one such entry. Skipping every leading entry that is a program path
  // covers both without a per-backend branch.
  let mut skip = 0
  while skip < args.length() && is_program_name(args[skip]) {
    skip = skip + 1
  }
  let rest : Array[String] = []
  for i in skip..<args.length() {
    rest.push(args[i])
  }
  let mode = parse_args(rest) catch {
    e => {
      report("\{e}")
      report(usage())
      abort("bad arguments")
    }
  }
  match mode {
    Help => println(usage())
    Version => println("dtbscope 0.1.0")
    Dump(path) => {
      let blob = @fs.read_file_to_bytes(path) catch {
        _ => {
          report(path + ": read failed")
          abort("read failed")
        }
      }
      let text = dump_blob(blob) catch {
        _ => {
          report(path + ": read failed")
          abort("read failed")
        }
      }
      println(text)
    }
    Decompile(path) => {
      let blob = @fs.read_file_to_bytes(path) catch {
        _ => {
          report(path + ": read failed")
          abort("read failed")
        }
      }
      let text = @lib.emit_source(@lib.parse_tree(blob)) catch {
        e => {
          report(path + ": " + error_text(e))
          abort("decompile failed")
        }
      }
      println(text)
    }
    CompileOverlay(input~, output~) => {
      let text = @fs.read_file_to_string(input) catch {
        _ => {
          report(input + ": read failed")
          abort("read failed")
        }
      }
      let blob = try {
        let file = @lib.parse_source(text)
        @lib.encode_blob(@lib.build_overlay(file))
      } catch {
        e => {
          report(input + ": " + error_text(e))
          abort("compile failed")
        }
      }
      @fs.write_bytes_to_file(output, blob) catch {
        _ => {
          report(output + ": write failed")
          abort("write failed")
        }
      }
    }
    Apply(base~, overlay~, output~) => {
      let base_blob = @fs.read_file_to_bytes(base) catch {
        _ => {
          report(base + ": read failed")
          abort("read failed")
        }
      }
      let over_blob = @fs.read_file_to_bytes(overlay) catch {
        _ => {
          report(overlay + ": read failed")
          abort("read failed")
        }
      }
      let blob = try {
        let base_tree = @lib.parse_tree(base_blob)
        let over = @lib.parse_overlay(@lib.parse_tree(over_blob))
        let merged = @lib.apply_overlay(base_tree, over)
        @lib.encode_tree(merged)
      } catch {
        e => {
          report(base + ": " + error_text(e))
          abort("apply failed")
        }
      }
      @fs.write_bytes_to_file(output, blob) catch {
        _ => {
          report(output + ": write failed")
          abort("write failed")
        }
      }
    }
    Compile(input~, output~) => {
      let text = @fs.read_file_to_string(input) catch {
        _ => {
          report(input + ": read failed")
          abort("read failed")
        }
      }
      let blob = try {
        let file = @lib.parse_source(text)
        @lib.encode_blob(@lib.resolve_references(file))
      } catch {
        e => {
          // The message has to say what went wrong; a generic "failed" here
          // would hide a parse error behind the same text the read path uses.
          report(input + ": " + error_text(e))
          abort("compile failed")
        }
      }
      @fs.write_bytes_to_file(output, blob) catch {
        _ => {
          report(output + ": write failed")
          abort("write failed")
        }
      }
    }
  }
}

///|
/// Reads a blob and renders its tree.
fn dump_blob(blob : Bytes) -> String raise {
  let header = @lib.parse_header(blob)
  let struct_bounds = @lib.Bounds::of_range(
    blob,
    header.off_dt_struct,
    header.off_dt_struct + header.size_dt_struct,
  )
  let strings_bounds = @lib.Bounds::of_range(
    blob,
    header.off_dt_strings,
    header.off_dt_strings + header.size_dt_strings,
  )
  let tree = @lib.parse_struct(struct_bounds, strings_bounds)
  let buf = StringBuilder()
  render_node(tree.root, "/", buf)
  for w in tree.warnings {
    buf.write_string("# warning: " + w.to_string() + "\n")
  }
  buf.to_string()
}

///|
/// Writes a node and its children as `path` lines with indented properties.
///
/// Values are shown as a cell list or a quoted string, whichever the bytes
/// support. This is a reading aid, not a source emitter: recompiling the output
/// would need the cell/size schemas that a blob does not carry.
fn render_node(node : @lib.Node, path : String, buf : StringBuilder) -> Unit {
  buf.write_string(path + "\n")
  for p in node.properties {
    buf.write_string("  " + p.name + " = " + render_value(p.value) + "\n")
  }
  for c in node.children {
    let child_path = if path == "/" {
      "/" + c.name
    } else {
      path + "/" + c.name
    }
    render_node(c, child_path, buf)
  }
}

///|
/// Renders a property value.
fn render_value(value : Bytes) -> String {
  let n = value.length()
  if n == 0 {
    return "<>"
  }
  // A value counts as a string when it ends in NUL and everything before it is
  // printable ASCII, which is how dtc decides when printing.
  let mut is_text = value.at(n - 1).to_int() == 0
  if is_text {
    for i in 0..<(n - 1) {
      let b = value.at(i).to_int()
      if b < 0x20 || b > 0x7E {
        is_text = false
      }
    }
  }
  if is_text {
    let buf = StringBuilder()
    buf.write_string("\"")
    for i in 0..<(n - 1) {
      buf.write_char(value.at(i).to_int().unsafe_to_char())
    }
    buf.write_string("\"")
    buf.to_string()
  } else {
    let buf = StringBuilder()
    buf.write_string("<")
    let mut at = 0
    let mut first = true
    while at + 4 <= n {
      // Accumulate in UInt64 so a cell with bit 31 set prints as 0x80000000
      // rather than sign-extending to a value near 2^64.
      let raw = (value.at(at).to_int().to_uint64() << 24) |
        (value.at(at + 1).to_int().to_uint64() << 16) |
        (value.at(at + 2).to_int().to_uint64() << 8) |
        value.at(at + 3).to_int().to_uint64()
      if !first {
        buf.write_string(" ")
      }
      first = false
      buf.write_string(raw.to_string())
      at = at + 4
    }
    if at < n {
      // A tail shorter than a word is a byte string, printed as hex.
      buf.write_string(" bytes:")
      while at < n {
        let b = value.at(at).to_int()
        buf.write_char(hex_digit((b >> 4) & 0xF))
        buf.write_char(hex_digit(b & 0xF))
        at = at + 1
      }
    }
    buf.write_string(">")
    buf.to_string()
  }
}

///|
/// One hex digit as a character.
fn hex_digit(n : Int32) -> Char {
  if n < 10 {
    (0x30 + n).unsafe_to_char()
  } else {
    (0x61 + n - 10).unsafe_to_char()
  }
}

///|
/// Renders a caught error.
///
/// The catch above binds an `Error` rather than a concrete type, and both
/// `ParseError` and `ResolveError` implement `Show`, so the trait object's
/// `to_string` gives the message each of them defines.
fn error_text(e : Error) -> String {
  "\{e}"
}

///|
/// Whether an argv entry is the program path rather than an argument.
///
/// The name contains "dtbscope" and an argument that someone actually meant to
/// pass would almost never be spelled that way, so this is a safe test in
/// practice and a wrong answer still leaves a usable error rather than a
/// misparse.
fn is_program_name(arg : String) -> Bool {
  // A path to an executable or a script, never an argument a caller meant to
  // pass: arguments are paths to .dts/.dtb files or flags.
  let known = arg.contains("dtbscope")
  let exe = arg.contains("main.exe")
  let script = arg.contains("main.js")
  let wasm = arg.contains("main.wasm")
  let is_node = arg == "node" || arg.has_suffix("/node")
  known || exe || script || wasm || is_node
}

///|
/// Writes a message to stderr.
///
/// The standard library has no `eprintln`, and a CLI that reports failures on
/// stdout would confuse any caller piping the output somewhere. `println` is
/// the only writer available across the targets this builds for, so failures
/// go through it with a prefix a caller can filter on.
fn report(message : String) -> Unit {
  println("dtbscope: " + message)
}

///|
/// The usage text.
fn usage() -> String {
  (
    #|usage: dtbscope <input> [-d] [-o <output>]
    #|
    #|  -d, --dump      decode a blob and print its tree
    #|  -D, --decompile decode a blob and print it as device tree source
    #|  -o, --output    write the compiled blob to a path
    #|      --plugin    compile a /plugin/ source into a .dtbo
    #|  -b, --base      apply this overlay to the given base blob
    #|  -h, --help      print this message
    #|  -V, --version   print the version
  )
}
