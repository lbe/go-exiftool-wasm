// Package exiftool runs ExifTool in-process via an embedded Perl interpreter
// (zeroperl) compiled to native Go via wasm2go, using the external
// github.com/lbe/wasm2go-wasi-host WASI implementation.
// No external exiftool binary or Perl installation is required.
//
// The Perl stdlib and ExifTool script are embedded as LZ4-compressed files and
// transparently decompressed on first read via an LRU cache.
//
// guest cwd is /host: Perl preamble in exiftoolEvalWrapper chdirs to hostWorkDir
// before ExifTool runs, so relative paths resolve against the writable host working
// directory mount rather than guest root /.
//
// Mount layout (assembled in buildModuleConfig via wasihost.NewModuleConfig):
//   - "/host" ([hostWorkDir]): primary writable preopen for the caller's working directory
//   - host cwd path aliases: additional writable preopens via registerHostDirPreopenAliases
//   - "/lib": read-only FS (wasihost.WithReadOnlyFS) serving the embedded Perl tree
//   - "/bin": read-only FS serving the ExifTool script
//   - "/dev": read-only devNullFS for /dev/null
//   - [os.TempDir]: writable preopen for ExifTool side effects
//   - operand parent directories: writable preopens from [operandPreopenDirs] for file
//     operands outside cwd and os.TempDir (Command only; see [commandWritableDirs]).
//     Operand preopens are writable host mounts; only pass paths you intend ExifTool to access.
//
// Entry points:
//   - [Command] / [CommandContext]: one-shot eval invocation; operand paths outside
//     cwd/temp are preopened and rewritten to host-absolute paths before ExifTool runs.
//   - [NewServer]: persistent ExifTool using the -stay_open protocol; amortises
//     Perl startup across many [Server.Command] calls. After [NewServer] returns,
//     call [Server.Shutdown] for graceful teardown. Use [Server.Close] to force-stop
//     without waiting (for example if Perl is still initializing).
//
// Configuration package variables [Arg1] and [Config] are forwarded into the
// ExifTool argument list for [Command]/[CommandContext] and [NewServer]. [Exec]
// is kept for API compatibility but is not used to spawn a process. Leave [Arg1]
// empty unless you intend to pass a valid ExifTool option: it is prepended
// verbatim and a mistaken value can be interpreted as a file argument.
//
// See ARCHITECTURE.md for mount layout, I/O model, and stay_open lifecycle details.
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
