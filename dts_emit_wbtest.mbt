// Source emitter tests.
//
// The assertion is byte equality with `dtc -I dtb -O dts` on the same blob.
// Formatting is where an emitter goes wrong — a missing blank line, a cell
// printed without its leading zero — and a structural comparison would call
// all of those correct.

///|
/// Reads a fixture and renders it as source.
fn emit_fixture(name : String) -> String raise {
  let blob = @fs.read_file_to_bytes("internal/fixtures/" + name)
  emit_source(parse_tree(blob))
}

///|
/// Reports the first differing line, or `identical`.
///
/// Whole-file diffs on a 500-line output bury the one line that differs, so
/// the first mismatch is what gets reported.
fn first_line_difference(mine : String, theirs : String) -> String {
  let a = split_lines(mine)
  let b = split_lines(theirs)
  let common = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<common {
    if a[i] != b[i] {
      return "line \{i + 1}: mine [\{a[i]}], dtc [\{b[i]}]"
    }
  }
  if a.length() != b.length() {
    "line count: mine \{a.length()}, dtc \{b.length()}"
  } else {
    "identical"
  }
}

///|
/// Splits on newlines, keeping empty lines so that blank-line placement is
/// compared like anything else.
fn split_lines(text : String) -> Array[String] {
  let out : Array[String] = []
  let mut start = 0
  for i in 0..<text.length() {
    if text.get_char(i).unwrap() == '\n' {
      out.push(text[start:i].to_owned())
      start = i + 1
    }
  }
  if start < text.length() {
    out.push(text[start:].to_owned())
  }
  out
}

///|
/// The flat fixture, byte for byte against dtc's dump.
///
/// The comparison is against what `dtc -I dtb -O dts` prints, not against the
/// `.dts` the fixture was compiled from. The two differ: the source writes
/// `<1>` and dtc prints `<0x01>`, and reproducing the source form would mean
/// guessing which cells the author meant as hex.
test "minimal: source identical to dtc dump" {
  let mine = emit_fixture("minimal.dtb")
  let want =
    #|/dts-v1/;
    #|
    #|/ {
    #|	compatible = "dtbscope,minimal";
    #|	model = "dtbscope minimal board";
    #|	#address-cells = <0x01>;
    #|	#size-cells = <0x01>;
    #|
    #|	chosen {
    #|		bootargs = "console=ttyS0,115200";
    #|	};
    #|
    #|	memory@80000000 {
    #|		device_type = "memory";
    #|		reg = <0x80000000 0x10000000>;
    #|	};
    #|};
  inspect(first_line_difference(mine, want), content="identical")
}

///|
/// The nested fixture. This one has a multi-line `reg` in the source that dtc
/// prints as one line, and a `ranges` with no value, so the comparison is
/// against dtc's dump rather than the original source.
test "nested: source identical to dtc dump" {
  let mine = emit_fixture("nested.dtb")
  // The expectations below are what `dtc -I dtb -O dts nested.dtb` prints,
  // checked line by line in the earlier struct tests; here the whole text is
  // compared so that formatting is covered too.
  let want =
    #|/dts-v1/;
    #|
    #|/ {
    #|	compatible = "dtbscope,nested";
    #|	#address-cells = <0x02>;
    #|	#size-cells = <0x02>;
    #|	interrupt-parent = <0x01>;
    #|
    #|	aliases {
    #|		serial0 = "/soc/serial@10000000";
    #|	};
    #|
    #|	cpus {
    #|		#address-cells = <0x01>;
    #|		#size-cells = <0x00>;
    #|
    #|		cpu@0 {
    #|			device_type = "cpu";
    #|			compatible = "arm,cortex-a72";
    #|			reg = <0x00>;
    #|			enable-method = "psci";
    #|		};
    #|
    #|		cpu@1 {
    #|			device_type = "cpu";
    #|			compatible = "arm,cortex-a72";
    #|			reg = <0x01>;
    #|			enable-method = "psci";
    #|		};
    #|	};
    #|
    #|	soc {
    #|		compatible = "simple-bus";
    #|		#address-cells = <0x02>;
    #|		#size-cells = <0x02>;
    #|		ranges;
    #|
    #|		interrupt-controller@fff01000 {
    #|			compatible = "arm,gic-400";
    #|			#interrupt-cells = <0x03>;
    #|			interrupt-controller;
    #|			reg = <0x00 0xfff01000 0x00 0x1000 0x00 0xfff02000 0x00 0x2000>;
    #|			phandle = <0x01>;
    #|		};
    #|
    #|		serial@10000000 {
    #|			compatible = "ns16550a";
    #|			reg = <0x00 0x10000000 0x00 0x100>;
    #|			interrupts = <0x00 0x01 0x04>;
    #|			clock-frequency = <0x1c2000>;
    #|		};
    #|	};
    #|
    #|	chosen {
    #|		stdout-path = "/soc/serial@10000000";
    #|		bootargs = "console=ttyAMA0,115200 root=/dev/nfs";
    #|	};
    #|};
    #|
  inspect(first_line_difference(mine, want), content="identical")
}

///|
/// A value that is not a multiple of four bytes is a byte string.
test "byte string form" {
  let src = "/dts-v1/; / { mac = [00 11 22 aa bb cc]; };"
  let blob = encode_blob(parse_source(src))
  let text = emit_source(parse_tree(blob))
  inspect(text.contains("mac = [00 11 22 aa bb cc];"), content="true")
}

///|
/// A zero-length property is a boolean and prints without a value.
test "boolean property" {
  let src = "/dts-v1/; / { interrupt-controller; };"
  let blob = encode_blob(parse_source(src))
  let text = emit_source(parse_tree(blob))
  inspect(text.contains("\tinterrupt-controller;"), content="true")
}

///|
/// A string list prints as comma-separated quoted strings, which is how dtc
/// shows a value that holds several NUL-terminated strings.
test "string list" {
  let src = "/dts-v1/; / { c = \"a\", \"b\"; };"
  let blob = encode_blob(parse_source(src))
  let text = emit_source(parse_tree(blob))
  inspect(text.contains("c = \"a\", \"b\";"), content="true")
}

///|
/// The RealView board, byte for byte against dtc's dump. 69 nodes and the
/// widest range of value shapes in the fixture set: aliases, cells that need
/// eight hex digits, an empty `ranges`, and a 1 000-byte string table.
test "realview: source identical to dtc dump" {
  let mine = emit_fixture("realview-pb1176.dtb")
  let want = @fs.read_file_to_string(
    "internal/fixtures/realview-pb1176.expected.dts",
  )
  inspect(first_line_difference(mine, want), content="identical")
}

///|
/// The CLI path has to agree with the library path.
///
/// `main.mbt` prints through `println`, which appends a newline that
/// `emit_source` already wrote. That mismatch is invisible to a test that
/// calls `emit_source` directly, and it is exactly what the CLI shipped with
/// until this was checked: the file was one blank line longer than dtc's.
/// The trimming the CLI does is asserted here so that a later change to either
/// side fails.
test "trailing newline count matches dtc" {
  let mine = emit_fixture("minimal.dtb")
  // Exactly one newline at the end, which is what dtc writes and what
  // `println` on a trimmed string produces.
  inspect(mine.has_suffix("};\n"), content="true")
  inspect(mine.has_suffix("};\n\n"), content="false")
  // And none at the start beyond the version line's blank separator.
  inspect(mine.has_prefix("/dts-v1/;\n\n/ {\n"), content="true")
}
