// Package exiftool runs ExifTool in-process via an embedded Perl interpreter
// (zeroperl) compiled to WebAssembly and executed with wazero. It is published
// from github.com/lbe/go-exiftool-wasm and does not require an external
// exiftool binary or Perl installation.
//
// Entry points:
//   - [Command] / [CommandContext]: one-shot invocation; host paths are relative to
//     the process working directory and are visible read-only under "/" inside the sandbox,
//     with [os.TempDir] mounted read-write for ExifTool side effects.
//   - [Run] / [RunDebug]: single invocation with an explicit [fs.FS] mounted at "/work";
//     pass paths such as "/work/photo.jpg".
//   - [NewServer]: persistent ExifTool using the -stay_open protocol; amortizes WASM
//     startup across many [Server.Command] calls. Call [Server.Shutdown] or [Server.Close]
//     when finished.
//
// Configuration package variables [Arg1] and [Config] are forwarded into the ExifTool
// argument list for [Command]/[CommandContext] and [NewServer]. [Exec] is kept for API compatibility
// but is not used to spawn a process. Leave [Arg1] empty unless you intend to pass a valid
// ExifTool option: it is prepended verbatim and a mistaken value can be interpreted as a
// file argument.
package exiftool

import "os"

// Exec is retained for compatibility with the original go-exiftool API.
// This implementation does not execute an external program; the value is ignored.
var Exec = "exiftool"

// Arg1, if non-empty, is prepended to every ExifTool argv built by [Command]/[CommandContext]
// and by [NewServer]. It must be a valid ExifTool argument (for example a global option).
// Do not set it to a host path unless that path is intended as an input file for ExifTool.
var Arg1 string

// Config, if non-empty, is passed as "-config" and the path value to ExifTool.
var Config string

// CacheDir controls where wazero stores its persistent compilation cache.
// If empty, a per-user default cache directory is used when available. On Unix,
// this follows [os.UserCacheDir], which respects XDG cache conventions.
//
// The underlying wazero cache is segregated by version, architecture, and OS,
// so it is safe to point multiple systems at a shared home directory as long as
// the cache root itself is shared.
//
// If set to "off", the package disables the persistent on-disk cache and uses
// only the in-memory cache for the current process.
var CacheDir string

func defaultCacheDir() string {
	dir, err := os.UserCacheDir()
	if err != nil || dir == "" {
		return ""
	}
	return dir + string(os.PathSeparator) + "go-exiftool-wasm"
}

func resolvedCacheDir() string {
	switch dir := CacheDir; dir {
	case "":
		return defaultCacheDir()
	case "off", "OFF", "Off":
		return ""
	default:
		return dir
	}
}
