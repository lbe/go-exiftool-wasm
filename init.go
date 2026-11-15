// Package exiftool runs ExifTool in-process, with no exiftool binary and no Perl
// installation. It embeds Perl and ExifTool as a WebAssembly module (zeroperl)
// that wasm2go has translated to native Go, and github.com/lbe/wasm2go-wasi-host
// implements the module's WASI system calls.
//
// # Files
//
// ExifTool sees the host filesystem at its real paths and can read and write any
// file the calling process can. Its working directory is the process working
// directory, so relative paths resolve as they do for a native exiftool. The
// embedded Perl tree occupies /lib and /bin, and /dev holds only /dev/null, so
// host files under those three directories are not reachable.
//
// # Entry points
//
// [Command] and [CommandContext] start a new interpreter for every call, which
// takes several hundred milliseconds. [NewServer] starts one interpreter that
// uses ExifTool's -stay_open protocol, and every [Server.Command] reuses it. Call
// [Server.Shutdown] to stop a server and wait for it, or [Server.Close] to stop it
// without waiting, for example while it is still starting.
//
// # Configuration
//
// [Arg1] and [Config] add arguments to every command and server. [Exec] exists
// for compatibility with github.com/ncruces/go-exiftool and is ignored.
//
// ARCHITECTURE.md in the repository describes the mount layout, the I/O model and
// the stay_open lifecycle.
package exiftool

// Exec is ignored. It exists for compatibility with github.com/ncruces/go-exiftool,
// where it names the exiftool binary to run.
var Exec = "exiftool"

// Arg1, if not empty, is the first argument of every command that [Command] and
// [CommandContext] run and of every server that [NewServer] starts. Set it only to
// a valid ExifTool option, because ExifTool treats any other value as a file name.
var Arg1 string

// Config, if not empty, is passed to ExifTool as "-config" followed by Config,
// after [Arg1].
var Config string
