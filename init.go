// Package exiftool runs ExifTool in-process via an embedded Perl interpreter
// (zeroperl) compiled to native Go via wasm2go with a custom WASI host layer.
// No external exiftool binary or Perl installation is required.
//
// The Perl stdlib and ExifTool modules are embedded as LZ4-compressed files and
// transparently decompressed on first read via an LRU cache.
//
// Entry points:
//   - [Command] / [CommandContext]: one-shot invocation; host paths are visible
//     read-only under "/" inside the sandbox, with [os.TempDir] mounted read-write
//     for ExifTool side effects.
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
// The Perl library layout segment is defined in perlversion.go (perl5Lib).
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
