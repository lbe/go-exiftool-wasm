# go-exiftool: ExifTool in Go (zeroperl + wazero)

[![Go Reference](https://pkg.go.dev/badge/github.com/lbe/go-exiftool-wasm.svg)](https://pkg.go.dev/github.com/lbe/go-exiftool-wasm)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Go Version](https://img.shields.io/badge/Go-1.26.0-blue.svg)](https://go.dev/dl/)
[![Go Report Card](https://goreportcard.com/badge/github.com/lbe/go-exiftool-wasm)](https://goreportcard.com/report/github.com/lbe/go-exiftool-wasm)
[![Release](https://github.com/lbe/go-exiftool-wasm/actions/workflows/releases.yml/badge.svg)](https://github.com/lbe/go-exiftool-wasm/actions/workflows/releases.yml)
[![CI](https://github.com/lbe/go-exiftool-wasm/actions/workflows/ci.yml/badge.svg)](https://github.com/lbe/go-exiftool-wasm/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/lbe/go-exiftool-wasm/branch/main/graph/badge.svg)](https://codecov.io/gh/lbe/go-exiftool-wasm)

Go library that runs **[ExifTool](https://exiftool.org/)** in-process: embedded **Perl** via **[zeroperl](https://github.com/6over3/zeroperl)** (Perl compiled to **WebAssembly**), executed with **[wazero](https://wazero.io/)**. You do **not** need a system `exiftool` binary or a separate Perl install.

This project should be considered alpha. The exported API is intended to remain compatible with [ncruces/go-exiftool](https://github.com/ncruces/go-exiftool), but the underlying [zeroperl](https://github.com/6over3/zeroperl) runtime is still experimental.

## Attributions

- This repo is a fork of [ncruces/go-exiftool](https://github.com/ncruces/go-exiftool). Many thanks to ncruces for the original project and for recommending an independent fork.
- This repo uses:
  - the excellent [ExifTool](https://exiftool.org/) by Phil Harvey
  - the experimental release of [zeroperl](https://github.com/6over3/zeroperl) by Andrew Sampson

## Why this shape

- **Self-contained** — Perl stdlib, ExifTool, and the interpreter ship inside the module (`embed/`).
- **Same behavior everywhere** — one WASM stack on Linux, macOS, Windows, etc.
- **Trade-off** — cold start is still much heavier than a native `exiftool` binary. This package now uses shared wazero compilation caches, so repeat starts are substantially cheaper than the very first start. For many operations, use **`NewServer`** and **`Server.Command`** so ExifTool stays open (`-stay_open`) and work is amortized.

## Requirements

- **Go 1.26+**
- Dependency: `github.com/tetratelabs/wazero` (see `go.mod`).

## Usage

```go
// One-shot: paths are relative to the process working directory.
out, err := exiftool.Command(nil, "-json", "photo.jpg")

// Explicit tree at /work (e.g. tests or isolated FS).
out, err := exiftool.Run(ctx, os.DirFS("/path/to/photos"), "-json", "/work/photo.jpg")

// Batch: one WASM/Perl startup, many commands.
e, err := exiftool.NewServer("-fast")
if err != nil { /* ... */ }
defer e.Shutdown()
out, err = e.Command("-Artist", "photo.jpg")
```

Package docs, API details, and filesystem semantics (`Command` vs `Run`, temp dir, `Arg1` / `Config`): run **`go doc -all`** or open [pkg.go.dev](https://pkg.go.dev/github.com/lbe/go-exiftool-wasm).

## Performance notes

- `Command` and `Run` are best for one-off operations.
- `NewServer` is the preferred path for bulk extraction and any workload that can reuse a long-lived worker.
- wazero compilation is cached:
  - in-memory within the current process
  - on disk across processes via `CacheDir`
- If `CacheDir` is left empty, the package uses the per-user cache root from `os.UserCacheDir()` when available.
- Set `exiftool.CacheDir = "off"` to disable the persistent on-disk compilation cache.

For high-throughput ingestion, the intended pattern is one persistent `Server` per worker goroutine plus a separate result writer.

## Development

### Tests

```bash
go test ./... -timeout 10m   # includes WASM tests; allow several minutes
go test -v ./... -cover -race -count=1
```

### Refreshing `embed/` from zeroperl

The WASM module, Perl install prefix, and minified ExifTool script come from **[zeroperl](https://github.com/6over3/zeroperl)**. Follow that repository’s **Build** section (Docker or Apple Container): build the image, run the container, and copy **`/artifacts`** into a host directory (as shown there, e.g. `./output/`).

From the build output directory, install these into **this** repo under `embed/`:

| Artifact from zeroperl output     | Path in go-exiftool       |
| --------------------------------- | ------------------------- |
| `zeroperl.wasm`                   | `embed/zeroperl.wasm`     |
| `perl-wasi-prefix/` (entire tree) | `embed/perl-wasi-prefix/` |
| `exiftool.min.pl`                 | `embed/exiftool.min.pl`   |

Use the **`zeroperl.wasm`** artifact (reactor **with** asyncify) unless you intentionally switch runtimes. If you disable ExifTool in zeroperl (`BUILD_EXIFTOOL=false`), you must supply `exiftool.min.pl` yourself.

zeroperl’s README also documents **build arguments** (`PERL_VERSION`, `EXIFTOOL_VERSION`, `BUILD_EXIFTOOL`, memory/stack, etc.). If you change **`PERL_VERSION`**, update the hard-coded **`PERL5LIB`** paths in `exiftool.go` and `server.go` so the version segment (e.g. `5.42.0`) matches the tree under `embed/perl-wasi-prefix/lib/`.

## License

Licensed under the [MIT License](LICENSE).

### Third-party licenses

| Component                    | License                      |
| ---------------------------- | ---------------------------- |
| ExifTool                     | Same as Perl                 |
| zeroperl                     | MIT                          |
