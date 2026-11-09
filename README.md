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

Early. The blob header parses and is validated; the struct and strings blocks
are next.

| Capability | Status |
|---|---|
| 40-byte blob header, version 17 | done |
| Block tiling and alignment validation | done |
| Bounds-checked primitive reads | done |
| Struct block walk (nodes, properties) | done |
| Strings block lookup | done |
| Nesting limit and cycle guard | done |
| DTS lexer: identifiers, strings, numbers, comments | done |
| DTS parser: nodes, properties, typed values | done |
| Labels, `&label` and `&{/path}` references | done |
| `/bits/` and `/memreserve/` | done |
| DTB writer | not started |
| Reference resolution (phandle assignment) | not started |
| DTS emitter | not started |
| Overlay application | not started |

## Quick start

```sh
moon test
```

Two fixtures: `minimal.dtb` is a flat board tree, `nested.dtb` has a CPU
subtree, an interrupt controller with a phandle and a `ranges` property that
encodes to nothing. Both are checked node by node against
`dtc -I dtb -O dts` on the same bytes.

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
| `tools/gen-fixtures.sh` | Fixture regeneration |
| `internal/fixtures/` | DTS sources and their compiled DTBs |

## Scope

The C preprocessor is out of scope. Kernel device tree sources use `#include`
and macros, and the kernel's own build runs `cpp` before `dtc`; this library
expects the same, so the input it takes is what `cpp` produced rather than the
file as it sits in the tree. `/incbin/` is likewise refused: it would make the
parse depend on files outside the source, and the resulting bytes depend on
data the source does not contain.

## Acknowledgements

The format is specified in the
[Devicetree Specification](https://www.devicetree.org/specifications/), v0.4.
Behaviour is compared against `dtc` from
[dgibson/dtc](https://github.com/dgibson/dtc), which is used only to produce
fixtures and to check output; no dtc code is part of this module.

Licensed under Apache-2.0.