# go-exiftool: ExifTool in Go (zeroperl + wasm2go)

[![Go Reference](https://pkg.go.dev/badge/github.com/lbe/go-exiftool-wasm.svg)](https://pkg.go.dev/github.com/lbe/go-exiftool-wasm)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Go Version](https://img.shields.io/badge/Go-1.27+-blue.svg)](https://go.dev/dl/)
[![Go Report Card](https://goreportcard.com/badge/github.com/lbe/go-exiftool-wasm)](https://goreportcard.com/report/github.com/lbe/go-exiftool-wasm)
[![Release](https://img.shields.io/github/v/release/lbe/go-exiftool-wasm)](https://github.com/lbe/go-exiftool-wasm/releases)
[![CI](https://github.com/lbe/go-exiftool-wasm/actions/workflows/go.yml/badge.svg)](https://github.com/lbe/go-exiftool-wasm/actions/workflows/go.yml)
[![codecov](https://codecov.io/gh/lbe/go-exiftool-wasm/branch/main/graph/badge.svg)](https://codecov.io/gh/lbe/go-exiftool-wasm)

This Go library runs [ExifTool](https://exiftool.org/) in-process.
[zeroperl](https://github.com/uswriting/zeroperl) compiles Perl to WebAssembly, wasm2go translates
that module to native Go, and [wasm2go-wasi-host](https://github.com/lbe/wasm2go-wasi-host) provides
its WASI system calls. You do not need a system `exiftool` binary or a Perl install.

ExifTool is written by Phil Harvey. See [exiftool.org](https://exiftool.org/) and
[exiftool/exiftool](https://github.com/exiftool/exiftool).

## Design

**Everything ships in the module.** The Perl standard library, ExifTool and the interpreter live
under `embed/` and `internal/zeroperl/`. The Perl tree is stored LZ4-compressed, and
[`perlFS()`](exiftool.go) decompresses each file on first read into a 2000-entry LRU cache
([`lbe/cfsread`](https://pkg.go.dev/github.com/lbe/cfsread)).

**The guest sees the host filesystem.** `buildModuleConfig` configures
[`wasm2go-wasi-host`](https://github.com/lbe/wasm2go-wasi-host) with one writable preopen of host
`/`, so a guest path is the same as the host path. Read-only mounts at `/lib` and `/bin` hold the
embedded Perl tree, and `/dev` holds `/dev/null`. Before ExifTool runs, the guest changes to the
caller's working directory.

**One implementation on Linux and macOS.** Windows is not supported yet. See
[Known limitations](#known-limitations).

**Start-up costs about 0.4 s.** That is the time to initialize the Perl runtime on a 24-core x86-64
Linux host. For many files, use `NewServer` and `Server.Command`. They keep one ExifTool running
with `-stay_open` and pay the start-up cost once.

## Requirements

- Go 1.27 or later.
- The dependencies in `go.mod`.

## Usage

```go
// One-shot: paths are relative to the process working directory.
out, err := exiftool.Command(nil, "-json", "photo.jpg")

// Batch: one Perl startup, many commands.
e, err := exiftool.NewServer("-fast")
if err != nil { /* ... */ }
defer e.Shutdown() // waits for the interpreter to exit; use Close to stop during start-up
out, err = e.Command("-Artist", "photo.jpg")
```

Run `go doc -all` or open [pkg.go.dev](https://pkg.go.dev/github.com/lbe/go-exiftool-wasm) for the
API, the mount layout, and `Arg1` and `Config`.

ExifTool receives file operands exactly as you pass them. A relative path resolves against the
process working directory. For a Server, that is the directory in effect when `NewServer` ran.
Absolute paths and symlinks work anywhere on the host.

`Shutdown` waits for the interpreter to exit. `Close` returns at once, and the interpreter stops at
its next host I/O call. Neither method can interrupt guest code while it computes. Do not call
either one while a command is running.

Each command reads and clears its own stderr. If the diagnostics exceed 64 KiB, the command returns
an overflow error, and later commands still work.

## Development

### Tests

See [TESTING.md](TESTING.md) and [ARCHITECTURE.md](ARCHITECTURE.md). The file name says what kind of
test it holds: `*_test.go` is a unit test with no build tag, `*_integration_test.go` needs the
`integration` tag, and `*_e2e_test.go` needs the `e2e` tag.

The `conformance_*_test.go` files hold immutable tests that check this package against
github.com/ncruces/go-exiftool. The full suite runs them against this package, and
`make conformance-ncruces` runs them against ncruces; see [TESTING.md](TESTING.md).

Run the unit tests:

```bash
go test ./... -count=1
```

Run the full suite, as CI does:

```bash
go test -tags=integration,e2e -race ./... -count=1
```

`make test-race ARGS="-count=1"` runs the same suite, and `make lint` runs golangci-lint.

### Refreshing `embed/` from zeroperl

The generated zeroperl Go source and the Perl install prefix come from
[zeroperl](https://github.com/uswriting/zeroperl). Follow the Build section of that repository with
Docker or Apple Container. Build the image, run the container, and copy `/artifacts` to a host
directory such as `./output/`.

Copy these files from the build output into this repository:

| Artifact from zeroperl output     | Path in go-exiftool             |
| --------------------------------- | ------------------------------- |
| `zeroperl.go`                     | `internal/zeroperl/zeroperl.go` |
| `perl-wasi-prefix/` (entire tree) | `embed/perl-wasi-prefix/`       |

Use the generated `zeroperl.go` unless you mean to switch runtimes. The package loads the ExifTool
script from `embed/perl-wasi-prefix/bin/exiftool`.

wasm2go built `internal/zeroperl/zeroperl.go` with `-embed`, and the module data sits next to it in
`zeroperl.dat`. Do not edit either file by hand.

After you copy `perl-wasi-prefix/` into `embed/` or run `dist.pl` (below), compress the tree in
place with LZ4:

```bash
go run github.com/lbe/cfsread/cmd/cfsread-lz4 embed/perl-wasi-prefix
```

The command keeps file names. It skips files that are already compressed or that do not shrink, so
you can run it again safely.

The zeroperl README also lists build arguments such as `PERL_VERSION`, `EXIFTOOL_VERSION`,
`BUILD_EXIFTOOL` and the memory and stack sizes. Each refresh fixes the prefix layout, for example
`lib/perl5` and `lib/perl5/wasm32-wasi`. `exiftoolEvalWrapper` adds those paths to `@INC` when it
runs ExifTool.

### Building the ExifTool prefix with `dist.pl`

`dist.pl` downloads, builds, minifies, tests and installs ExifTool into `embed/perl-wasi-prefix/`.

```bash
perl dist.pl --exiftool-version 13.56
```

It picks the version from the first of these that is set:

1. `--exiftool-version`
2. The `EXIFTOOL_VERSION` environment variable
3. The latest version listed on `https://exiftool.org/history.html`

## Writing files

`Command` and `CommandContext` accept paths relative to the process working directory and absolute
host paths. ExifTool can write or overwrite any file the process can, with flags such as
`-overwrite_original` or `-o <outfile>`.

## Known limitations

- The guest resolves `..` after a symlink lexically, but native ExifTool follows the symlink first.
  Pass clean paths.
- The embedded mounts hide host files under `/lib`, `/bin` and `/dev`.
- Windows is not supported until wasm2go-wasi-host builds there.
- A failed command returns a plain error, not an `*exec.ExitError`, so there is no `ExitCode()` or
  `Stderr` field. The error text includes stderr.
- `Exec` is kept for compatibility but ignored. ExifTool always runs in-process.

## License

See [LICENSE](LICENSE). ExifTool and the other embedded components carry their own licenses under
`embed/`.
