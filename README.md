# go-exiftool: ExifTool in Go (zeroperl + wasm2go)

[![Go Reference](https://pkg.go.dev/badge/github.com/lbe/go-exiftool-wasm.svg)](https://pkg.go.dev/github.com/lbe/go-exiftool-wasm)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Go Version](https://img.shields.io/badge/Go-1.26.0-blue.svg)](https://go.dev/dl/)
[![Go Report Card](https://goreportcard.com/badge/github.com/lbe/go-exiftool-wasm)](https://goreportcard.com/report/github.com/lbe/go-exiftool-wasm)
[![Release](https://img.shields.io/github/v/release/lbe/go-exiftool-wasm)](https://github.com/lbe/go-exiftool-wasm/releases)
[![CI](https://github.com/lbe/go-exiftool-wasm/actions/workflows/go.yml/badge.svg)](https://github.com/lbe/go-exiftool-wasm/actions/workflows/go.yml)
[![codecov](https://codecov.io/gh/lbe/go-exiftool-wasm/branch/main/graph/badge.svg)](https://codecov.io/gh/lbe/go-exiftool-wasm)

Go library that runs **[ExifTool](https://exiftool.org/)** in-process: embedded **Perl** via
**[zeroperl](https://github.com/uswriting/zeroperl)** (Perl compiled to **WebAssembly**), executed
as native Go via a wasm2go-generated module. You do **not** need a system `exiftool` binary or a
separate Perl install.

Upstream ExifTool (Phil Harvey) and metadata: [exiftool.org](https://exiftool.org/),
[exiftool/exiftool](https://github.com/exiftool/exiftool).

## Why this shape

- **Self-contained** — Perl stdlib, ExifTool, and the interpreter ship inside the module (`embed/`).
  The stdlib is stored LZ4-compressed; [`perlFS()`](exiftool.go) transparently decompresses files on
  first read using a 2000-entry LRU cache
  ([`lbe/cfsread`](https://pkg.go.dev/github.com/lbe/cfsread)).
- **Same behavior everywhere** — one toolchain-based interpreter implementation on Linux, macOS,
  Windows, etc.
- **Trade-off** — cold start is heavy (on the order of **~7–10 seconds** to initialize the
  wasm2go-backed Perl runtime). For many operations, use **`NewServer`** and **`Server.Command`** so
  ExifTool stays open (`-stay_open`) and work is amortized.

## Requirements

- **Go 1.26+**
- Dependencies are listed in `go.mod`.

## Usage

```go
// One-shot: paths are relative to the process working directory (host cwd is
// layered read-only under "/" alongside the embedded perl prefix).
out, err := exiftool.Command(nil, "-json", "photo.jpg")

// Batch: one Perl startup, many commands.
e, err := exiftool.NewServer("-fast")
if err != nil { /* ... */ }
defer e.Shutdown()
out, err = e.Command("-Artist", "photo.jpg")
```

Package docs, API details, and filesystem semantics (mount layout, temp dir, `Arg1` / `Config`): run
**`go doc -all`** or open [pkg.go.dev](https://pkg.go.dev/github.com/lbe/go-exiftool-wasm).

## Development

### Tests

```bash
go test ./... -timeout 10m   # allow several minutes for interpreter-heavy paths
```

### Refreshing `embed/` from zeroperl

The generated zeroperl Go source and Perl install prefix come from
**[zeroperl](https://github.com/uswriting/zeroperl)**. Follow that repository’s **Build** section
(Docker or Apple Container): build the image, run the container, and copy **`/artifacts`** into a
host directory (as shown there, e.g. `./output/`).

From the build output directory, install these into **this** repo under `embed/`:

| Artifact from zeroperl output     | Path in go-exiftool             |
| --------------------------------- | ------------------------------- |
| `zeroperl.go`                     | `internal/zeroperl/zeroperl.go` |
| `perl-wasi-prefix/` (entire tree) | `embed/perl-wasi-prefix/`       |

Use the generated **`zeroperl.go`** artifact unless you intentionally switch runtimes. The ExifTool
script is loaded from `embed/perl-wasi-prefix/bin/exiftool` in the embedded prefix.

After copying `perl-wasi-prefix/` into `embed/`, run **`go generate ./...`** to re-compress the tree
with `cfsread-lz4`. This updates the LZ4-compressed files in place so the embedded binary reflects
the new Perl build.

zeroperl’s README also documents **build arguments** (`PERL_VERSION`, `EXIFTOOL_VERSION`,
`BUILD_EXIFTOOL`, memory/stack, etc.). If you change **`PERL_VERSION`**, update the **`perl5Lib`**
segment in [perlversion.go](perlversion.go) so the runtime `PERL5LIB` path (`/lib/<segment>/…`)
stays aligned with the embedded prefix layout.

### Building ExifTool prefix with `dist.pl`

Use `dist.pl` to download, build, minify, test, and install ExifTool into `embed/perl-wasi-prefix/`.

```bash
perl dist.pl --exiftool-version 13.56
```

Version resolution precedence is:

1. `--exiftool-version`
2. `EXIFTOOL_VERSION` environment variable
3. Latest version parsed from `https://exiftool.org/history.html`

## License

See [LICENSE](LICENSE). ExifTool and embedded components carry their own licenses under `embed/`.
