# Spec: Native wasm2go Wrapper for go-exiftool

**Date:** 2026-04-04
**Status:** Design Approved

## Goal

Replace the wazero-based WASM runtime with a native Go wrapper around the wasm2go-generated `zeroperl/zeroperl.go`, eliminating the WASM compilation step that causes **>2 second NewServer startup** on current hardware.

## Constraints

- Exported signatures in `cmd.go`, `server.go`, `decode.go`, `printer.go` **must not change**. Implementation bodies may change.
- Package vars `Exec`, `Arg1`, `Config` in `init.go` must not change.
- All existing `*_test.go` files (except `exiftool_test.go`) must pass without modification.
- `zeroperl/zeroperl.go` is not edited.

## Known Risks

| Risk | Impact | Mitigation |
|---|---|---|
| **600MB+ generated source**, ~30 min compile | Long dev iteration, large binaries | Acceptable for research phase. Re-evaluate after validation. |
| Go linker cannot tree-shake the `elements` table (`[]any` slice in `New()`) | Binary stays large | May need downstream optimization (split package, build caching) |
| WASI implementation incomplete for Perl's needs | Runtime failures | Incremental validation: `-ver` first, then JSON read, then server |
| `proc_exit` panic conflicts with Go runtime | Crashes | Following proven go-sqlite3 pattern; recover at eval boundary |
| ChannelIO latency too high | Slow server responses | GuestIO interface designed for swap to BufferIO later |

## Performance Targets

| Metric | Current (wazero) | Target (wasm2go) |
|---|---|---|
| `NewServer` startup | **>2 seconds** | Sub-second (Perl init only) |
| Cold `Command` call | ~2 seconds | Sub-second |
| Compile time | Standard Go | ~30 minutes (acceptable for research) |

## Architecture

```
┌─────────────────────────────────────────────┐
│  Unchanged API surface                      │
│  cmd.go / server.go / decode.go / printer.go│
├─────────────────────────────────────────────┤
│  exiftool.go (rewritten internals)           │
│  newModule() → wasm2go.New + WASI state      │
│  evalModule() → Xzeroperl_init + eval        │
├──────────────────┬──────────────────────────┤
│  wasi.go (new)   │  io.go (new)             │
│  Xwasi_snapshot  │  GuestIO interface       │
│  _preview1 impl  │  DirectIO (single-shot)  │
│  + Xenv stub     │  ChannelIO (server)      │
├──────────────────┴──────────────────────────┤
│  zeroperl/zeroperl.go (untouched)           │
└─────────────────────────────────────────────┘
```

## New Files

### `wasi.go` — WASI Implementation

Implements `Xwasi_snapshot_preview1` and `Xenv` interfaces from `zeroperl/zeroperl.go`.

**Core types:**

- `wasiState` struct: module pointer, fd table, mount list, GuestIO reference
- `exitPanic struct{ code int32 }` — sentinel for proc_exit, recovered at eval boundary
- `fdEntry` struct: file handle, path, flags, fd type
- `mountEntry` struct: guest path prefix, backing `fs.FS`, writable flag

**File descriptor table:**

- FDs 0-2: stdin/stdout/stderr routed through GuestIO
- FD 3: preopened `/` (perlFS or overlayFS)
- FD 4: preopened `/dev` (devNullFS)
- FD 5: optional preopened `/work` (workFS from Run)
- FD 6+: dynamically opened files

**proc_exit handling:**

```go
func (w *wasiState) Xproc_exit(code int32) {
    panic(exitPanic{code: code})
}
```

All calls to `Xzeroperl_eval` wrapped in `recover()`. Exit code 0 = success, non-zero = error.

**Filesystem mount resolution:**

Same overlay semantics as current wazero implementation:

- `Run`: perlFS at `/`, optional workFS at `/work`
- `Command`/`Server`: overlayFS(perlFS, os.DirFS(".")) at `/`, os.TempDir writable
- `/dev`: devNullFS

**Key WASI methods:**

| Method | Strategy |
|---|---|
| `Xpath_open` | Resolve path against mounts, open via `fs.FS.Open` or `os.Open` for writable dirs, return new fd |
| `Xfd_read` | Read from fd entry into `module.memory[ptr:ptr+n]` |
| `Xfd_write` | Write from `module.memory[ptr:ptr+n]` to fd entry (stdout/stderr route through GuestIO) |
| `Xfd_close` | Close underlying file, free fd slot |
| `Xfd_seek` / `Xfd_tell` | Seek/tell on underlying file |
| `Xfd_fdstat_get` | Return type + flags for the fd |
| `Xfd_readdir` | List directory entries from `fs.ReadDir` |
| `Xpath_filestat_get` | Stat via `fs.Stat` or `os.Stat` |
| `Xpath_create_directory` | `os.Mkdir` on writable mount |
| `Xpath_unlink_file` | `os.Remove` on writable mount |
| `Xpath_rename` | `os.Rename` on writable mount |
| `Xenviron_get` / `Xenviron_sizes_get` | Return `PERL5LIB=/lib/5.42.0:/lib/5.42.0/wasm32-wasi` |
| `Xclock_time_get` | `time.Now().UnixNano()` |
| `Xrandom_get` | `crypto/rand.Read` |
| `Xpoll_oneoff` | Minimal implementation |
| `Xproc_exit` | `panic(exitPanic{code})` |

**env stub:**

```go
func (w *wasiState) Xcall_host_function(v0, v1, v2 int32) int32 {
    return 0
}
```

### `io.go` — GuestIO Abstraction

Designed for swappability (channel-based now, buffer-based later):

```go
type GuestIO interface {
    ReadStdin(buf []byte) (int, error)
    WriteStdout(buf []byte) (int, error)
    WriteStderr(buf []byte) (int, error)
    CloseStdin()
    CloseAll()
}
```

**DirectIO** — for single-shot Run/Command:

- stdin: `io.Reader`
- stdout/stderr: `*bytes.Buffer`
- No channels, direct reads/writes

**ChannelIO** — for Server stay_open mode:

- stdin: `chan []byte` (host sends command lines)
- stdout: `chan []byte` (guest sends output)
- stderr: `chan []byte` (guest sends errors)
- `ReadStdin` blocks on channel, reassembles partial reads
- `WriteStdout`/`WriteStderr` send on channels
- Designed to be swapped with a buffer-based implementation without touching wasi.go

## Modified Files

### `exiftool.go` — Full Rewrite of Internals

**Removed:** All wazero imports, `wazero.Runtime`, `wazero.CompiledModule`, overlayFS/devNullFS structs (moved to wasi.go).

**Kept:** Embed directives (`perl-wasi-prefix`, `exiftool.min.pl`), `perlFS()`, `commandArgs()`, `scriptPreamble`.

**New core functions:**

- `newModule(guestIO GuestIO, rootFS fs.FS, workFS fs.FS, writableDirs []string) (*wasm2go.Module, *wasiState, error)` — creates module, initializes WASI state, calls `X_initialize()`.
- `evalModule(mod, ws, script, args)` — calls `Xzeroperl_init`, allocates script+args in module memory, calls `Xzeroperl_eval` inside panic/recover, returns stdout bytes.
- `Run` / `RunDebug`: Create `DirectIO`, call `newModule` + `evalModule`. Same signatures.

### `server.go` — Implementation Body Changes

- `Server` struct: Replace `wazero.Runtime`, `wazero.CompiledModule`, `api.Module`, pipe fields with `*wasm2go.Module`, `*wasiState`, `*ChannelIO`.
- `NewServer()`: Replace `newRuntime` + `CompileModule` with `newModule(ChannelIO)`.
- `start()`: Create `ChannelIO`, build module, start goroutine calling `Xzeroperl_eval`.
- `Command()`: Write args to `ChannelIO.stdinCh`, read response from `ChannelIO.stdoutCh`/`stderrCh`. Same `splitReadyToken` framing.
- `Shutdown`/`Close`: Send `-stay_open false` via channel, close channels, recover goroutine.
- **Removed:** `os.Pipe` usage, `closeModules` helper, wazero `api.Closer` calls.
- **Kept:** `splitReadyToken`, `boundary` const, `processStub`/`cmdStub`, locking pattern, restart logic.

### `cmd.go` — Implementation Body Changes

- `Command`/`CommandContext`: Replace `newRuntime` + `CompileModule` + wazero `evalModule` with `newModule(DirectIO{...})` + native `evalModule`. Same signatures.

## Dependency Changes

- **Remove:** `github.com/tetratelabs/wazero`
- **Promote:** `github.com/ncruces/wasm2go` from indirect to direct

## Validation Order

1. `go build` succeeds (accept ~30 min compile)
2. `TestExiftoolVersion` passes (`-ver`, no file I/O)
3. `TestExiftoolJSON` passes (file read from workFS)
4. `TestExiftoolMultipleArgs` passes
5. Server tests pass (`server_test.go`, `cmd_test.go`)
6. Benchmarks show startup improvement
