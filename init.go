// Package exiftool runs ExifTool in-process via an embedded Perl interpreter
// (zeroperl) compiled to native Go via wasm2go, using the external
// github.com/lbe/wasm2go-wasi-host WASI implementation.
// No external exiftool binary or Perl installation is required.
//
// The Perl stdlib and ExifTool script are embedded as LZ4-compressed files and
// transparently decompressed on first read via an LRU cache.
//
// Mount layout:
//   - "/": writable host directory preopen (caller's working directory)
//   - "/lib": read-only FS serving the embedded Perl standard library
//   - "/bin": read-only FS serving the ExifTool script
//   - "/dev": read-only devNullFS for /dev/null
//   - [os.TempDir] (and any additional dirs): writable host directory preopens
//
// Entry points:
//   - [Command] / [CommandContext]: one-shot invocation; the caller's working
//     directory is mounted writable at "/" with [os.TempDir] for side effects.
//   - [NewServer]: persistent ExifTool using the -stay_open protocol; amortises
//     Perl startup across many [Server.Command] calls. Call [Server.Shutdown] or
//     [Server.Close] when finished.
//
// Configuration package variables [Arg1] and [Config] are forwarded into the
// ExifTool argument list for [Command]/[CommandContext] and [NewServer]. [Exec]
// is kept for API compatibility but is not used to spawn a process. Leave [Arg1]
// empty unless you intend to pass a valid ExifTool option: it is prepended
// verbatim and a mistaken value can be interpreted as a file argument.
//
// The Perl library layout segment (perl5Lib) determines the PERL5LIB path
// inside the guest (e.g. /lib/5.16.3, /lib/5.16.3/wasm32-wasi). It was
// formerly defined in perlversion.go; after the migration the layout is
// fixed within the embedded perl-wasi-prefix tree.
package exiftool

// Exec is retained for compatibility with the original go-exiftool API.
// This implementation does not execute an external program; the value is ignored.
var Exec = "exiftool"

// Arg1, if non-empty, is prepended to every ExifTool argv built by [Command]/[CommandContext]
// and by [NewServer]. It must be a valid ExifTool argument (for example a global option).
// Do not set it to a host path unless that path is intended as an input file for ExifTool.
var Arg1 string

// Config, if non-empty, is passed as "-config" and the path value to ExifTool.
var Config string
