# dtbscope

Device tree compiler and inspector in pure MoonBit.

Reads and writes the flattened device tree blob format that firmware hands to
the kernel at boot. No `dtc` binary, no C toolchain, no host operating system
assumptions: the same code compiles to Wasm and to native, so a device tree can
be inspected in a browser as easily as in a build script.

## Why

Every ARM and RISC-V board in production describes its hardware in a device
tree, and the only tool that compiles one is `dtc`, a C program that has to be
built and installed before it can run. That is fine on a Linux build host and
awkward everywhere else: a Mac developer cannot read a `.dtb` pulled off a
board, a CI runner has to `apt-get` a native package to check that an overlay
applies cleanly, and a browser cannot do either.

MoonBit compiles to both Wasm and native from one source, which is the property
this project is built around.

## Status

Working end to end. Compiles DTS to DTB, reads DTB back, generates and applies
overlays. Every fixture is byte-identical to what dtc produces for the same
source.

| Capability | Status |
|---|---|
| 40-byte blob header, version 17 | done |
| Block tiling and alignment validation | done |
| Bounds-checked primitive reads | done |
| Struct block walk (nodes, properties) | done |
| Strings block lookup | done |
| Nesting limit | done |
| DTS lexer: identifiers, strings, numbers, comments, cpp markers | done |
| Expressions `( ... )`: full C operator set and precedence | done |
| `/include/` with cycle detection and relative paths | done |
| `/bits/ 8`, `/bits/ 16`, `/bits/ 64` | done |
| `/delete-node/`, `/delete-property/` | done |
| `/omit-if-no-ref/` | done |
| Top-level `&label { }` patches, multiple root blocks | done |
| DTS parser: nodes, properties, typed values | done |
| Labels, `&label` and `&{/path}` references | done |
| `/bits/`, `/memreserve/`, `/plugin/` | done |
| DTB writer | done |
| Reference resolution, phandle numbering | done |
| Overlay generation, `__fixups__` | done |
| Overlay application, merge semantics | done |
| CLI: dump, decompile, compile, plugin compile, apply | done |
| Source emitter, byte-identical to dtc's dump | done |
| Browser demo (JavaScript backend) | done |
| DTS emitter (tree back to readable source) | done |
| C preprocessor and macros (`#include`, `#define`) | out of scope |
| `/incbin/` | out of scope |

### Verified against dtc

Every blob this module writes is compared byte for byte with dtc's output for
the same source. Seven fixtures:

| Fixture | Size | Nodes | What it covers |
|---|---|---|---|
| `minimal` | 357 B | 3 | flat tree, strings and cells |
| `nested` | 1 086 B | 9 | CPU subtree, phandle, multi-line `reg`, empty `ranges` |
| `overlay-base` | 657 B | 5 | base tree built with `-@`: `__symbols__`, a phandle |
| `overlay-labels` | 403 B | 4 | three labels on one node, label order on the way back out |
| `overlay-uart` | 381 B | 4 | `/plugin/` patches, `__fixups__` |
| `language` | 249 B | 3 | composes nine constructs at once: include, patch, delete-property, delete-node by reference, expression, label, unit address, boolean, text |
| `realview-pb1176` | 9 983 B | 69 | ARM board from the Linux tree: aliases, dma-ranges, 14 phandles |

The other direction is checked the same way: `emit_source` on a blob produces
the text `dtc -I dtb -O dts` prints, byte for byte. That includes the 559-line
dump of the RealView board, which has every value shape the fixtures contain.
The output is kept in `internal/fixtures/realview-pb1176.expected.dts`.

The RealView fixture is the one that matters. It is where the phandle
numbering rule surfaced: the two hand-written fixtures agree with dtc under
both orderings this project tried, and only a tree with fourteen references
tells them apart.

### Size

| Part | Lines |
|---|---|
| Library | 5 615 |
| Tests (`*_wbtest.mbt`) | 2 159 |
| CLI and browser entry points | 385 |

90 tests. `moon check --deny-warn` and `moon fmt --check` are clean.

## Performance

Measured on an M-series Mac, Node 22, JavaScript backend, after warm-up:

| Operation | Time |
|---|---|
| Parse and render a 9 983-byte blob (69 nodes) | 0.24 ms |
| Throughput | ~4 300 parses/s |
| Compile the same source from the CLI, process start included | 20–60 ms |

Speed was never the constraint: a device tree is read once at boot and is a
few kilobytes. The number matters only as a ceiling, and the ceiling is far
above anything a boot path needs.

## Quick start

```sh
moon test
```

Encode a source file and compare it with dtc:

```sh
moon run cmd/main -- internal/fixtures/nested.dts -o /tmp/out.dtb
dtc -q -I dts -O dtb -o /tmp/dtc.dtb internal/fixtures/nested.dts
cmp /tmp/out.dtb /tmp/dtc.dtb
```

And back:

```sh
moon run cmd/main -- /tmp/out.dtb -D > /tmp/round.dts
dtc -q -I dtb -O dts -o /tmp/dtc.dts /tmp/out.dtb
diff /tmp/round.dts /tmp/dtc.dts
```

Six fixtures. `minimal.dtb` is a flat board tree; `nested.dtb` has a CPU
subtree, an interrupt controller with a phandle and a `ranges` property that
encodes to nothing; `overlay-base` and `overlay-labels` are the two built with
`-@`, so they carry `__symbols__`; `overlay-uart` is the plugin that patches the
first; `realview-pb1176` is the ARM RealView PB1176 from the Linux tree, 69
nodes with aliases, dma-ranges and 14 phandles. Every one is compared byte for
byte against dtc in the compile direction, and against `dtc -I dtb -O dts` in
the other.

The RealView source is stored in its preprocessed form. The file in the kernel
tree begins with `#include`, and cpp has to run before either tool sees it;
keeping the post-cpp text means the comparison does not depend on which header
revisions the machine has.

Fixtures live in `internal/fixtures` as DTS sources plus the DTB that
`dtc 1.8.1` produced from them. The blob is checked in so the tests do not need
dtc; `tools/gen-fixtures.sh` regenerates it, and `tools/gen-fixtures.sh --check`
verifies it still matches, which is what CI runs.

## Layout

| File | Contents |
|---|---|
| `dtbscope.mbt` | Error type, cursor, hex formatting |
| `reader.mbt` | Bounds-checked reads of the primitive types |
| `header.mbt` | Blob header parse and validation |
| `struct_block.mbt` | Token walk, node tree, structural warnings |
| `dts_token.mbt` | Token kinds, spans, scanner state |
| `dts_lex.mbt` | Character rules and token scanning |
| `dts_parse.mbt` | Source grammar, value parsing, source tree |
| `dts_emit.mbt` | Tree back to source, byte-identical to dtc's dump |
| `dump.mbt` | Flat tree reading, shared by the CLI and the browser module |
| `phandle.mbt` | Label table, phandle numbering, reference rewrite |
| `dtb_write.mbt` | Blob encoder |
| `cmd/main/` | Command line front end |
| `overlay.mbt` | Overlay generation, fixups, application |
| `wasm/` | JavaScript entry points for the browser demo |
| `web/` | Demo page, built into `web/dist` by `tools/build-web.sh` |
| `tools/gen-fixtures.sh` | Fixture regeneration |
| `internal/fixtures/` | DTS sources and their compiled DTBs |

## Overlays

An overlay patches a base tree it cannot see. A reference in one is written as
the reserved word `0xffffffff` and recorded in `__fixups__` as the node,
property and byte offset to patch; the loader reads the base tree's
`__symbols__` to turn the label into a path, then writes the base tree's
phandle into that word.

```sh
# Compile a plugin source to a .dtbo
moon run cmd/main -- board-overlay.dts --plugin -o board.dtbo

# Apply it to a base blob and write the merged result
moon run cmd/main -- board.dtbo -b board.dtb -o merged.dtb
```

The base tree has to be built with symbols (`dtc -@`), because that is where
the labels are. Application merges rather than replaces: a fragment that sets
one property on a node keeps the base tree's other properties on it.

## Browser demo

```sh
./tools/build-web.sh
python3 -m http.server -d web/dist 8000
```

`web/dist` is a static directory. The page imports the MoonBit JavaScript
module directly, and `Bytes` maps to `Uint8Array` on both sides, so a dropped
file goes into the parser with no marshalling.

The JavaScript backend is used rather than wasm-gc because wasm-gc values are
GC-managed references: calling into that module from a page needs a glue layer
this project does not ship, while the JS backend emits a module a page imports
directly.

## Scope

The C preprocessor is out of scope. Kernel device tree sources use `#include`
and macros, and the kernel's own build runs `cpp` before `dtc`; this library
expects the same, so the input it takes is what `cpp` produced rather than the
file as it sits in the tree. `/incbin/` is likewise refused: it would make the
parse depend on files outside the source, and the resulting bytes depend on
data the source does not contain.

`/include/` is **not** the preprocessor and is supported. It is part of the DTS
grammar — dtc reads it itself, without cpp — so a source that uses it is this
library's input rather than something that has to be expanded beforehand.
Paths resolve relative to the including file, cycles are detected, and nesting
is capped at 32 levels. The same goes for the rest of the syntax that a
preprocessor is not involved in:

| Feature | Behaviour |
|---|---|
| `( expr )` | C operators and precedence, evaluated at parse time |
| `/include/ "file"` | spliced in, relative to the including file, cycles refused |
| `/delete-node/ &label;` | top-level form: names a node from anywhere, resolved against the finished tree |
| `/delete-node/ name;` | in-body form: removes the sibling already merged, not one declared later |
| `/delete-property/ name;` | removes a property inside a patch body |
| `/omit-if-no-ref/` | drops the node when nothing refers to it |
| `&label { }` after the root | patches the tree just read |
| several `/ { };` blocks | merged into one root, which is what an include produces |

The one thing these have in common is that dtc implements each of them and cpp
implements none. A source that needs none of them is also accepted, so dropping
an unsupported construct never silently changes what the rest of the file
means.

### The two forms of `/delete-node/`

They are separate constructs with separate rules, and the difference is not
cosmetic.

`/delete-node/ &label;` or `/delete-node/ &{/path};` names a node from anywhere
in the file. The label table is built first, so the directive may appear before
the node it names. An unknown target is an error.

`/delete-node/ name;` sits inside a node body and names a **sibling of that
body**. It is applied while the body is merged, so it reaches a sibling already
merged and nothing else:

```dts
soc {
    a@1 { };                    // merged first
    /delete-node/ b@2;          // nothing named b@2 yet: no-op
    b@2 { };                    // survives
};
```

Four rules follow from that, and each is easy to get wrong by tidying the
implementation:

- A node deleted and then re-declared keeps the properties it had before,
  because deletion flags the node rather than unlinking it and the
  re-declaration merges into the same one.
- A marker for a name that was never declared is a silent no-op.
- A property may not follow a subnode in the same body, but a marker may.
- One body cannot declare a node and then mark it: dtc's duplicate check scans
  the child list with an asymmetry that makes exactly this combination an
  error, while the same two lines in the other order are fine.

All four are covered by tests whose expected behaviour was read off dtc 1.8.1
on the same source rather than inferred from the grammar.

## Acknowledgements

The format is specified in the
[Devicetree Specification](https://www.devicetree.org/specifications/), v0.4.
Behaviour is compared against `dtc` from
[dgibson/dtc](https://github.com/dgibson/dtc), which is used only to produce
fixtures and to check output; no dtc code is part of this module.

Licensed under Apache-2.0.