# Enhancement: WritableDirs — Per-Call Writable Directory Control

**Status:** Deferred — not included in Remediation Plan 1  
**Applicability:** Any Go module that embeds a WASI sandbox and needs callers to control writable
mounts without changing function signatures.

---

## Problem

The WASI sandbox model grants writable filesystem access only to explicitly mounted directories.
When the sandbox is used as an FFI transport (not a security boundary), this creates friction:
callers who need to write to paths outside `os.TempDir()` currently have no way to declare those
paths without a code change inside the host package.

The current remediation mounts CWD writable by default, which covers the common case. However,
applications that operate on files in **arbitrary absolute paths** — not necessarily under CWD —
still cannot write there without modification to the host package.

---

## Proposed Solution

Add a package-level variable `WritableDirs []string` to `init.go`, following the existing
`Arg1`/`Config` pattern. The host reads it at call time and appends the listed paths to the
writable mount list alongside `os.TempDir()`.

### Declaration (init.go)

```go
// WritableDirs lists absolute host directory paths that the guest may write to.
// Each path is mounted read-write inside the WASI sandbox in addition to
// [os.TempDir] and the process working directory, which are always writable.
//
// Set this before calling [Command] or [CommandContext] when the guest must
// write to paths outside those defaults (for example, writing to a mounted
// network share or a fixed application data directory).
//
// Paths must be absolute. Duplicates and paths already covered by the default
// writable mounts are silently ignored. The zero value (nil) is safe.
var WritableDirs []string
```

### Integration (cmd.go)

```go
// dedupDirs returns dirs with duplicates removed, preserving order.
// Prevents double-mounting when WritableDirs overlaps with defaults.
func dedupDirs(dirs []string) []string {
    seen := make(map[string]struct{}, len(dirs))
    out := dirs[:0:0]
    for _, d := range dirs {
        if _, ok := seen[d]; !ok {
            seen[d] = struct{}{}
            out = append(out, d)
        }
    }
    return out
}

// In CommandContext, replace:
//   newModule(guestIO, defaultRootFS(), nil, []string{os.TempDir()})
// with:
//   cwd, _ := os.Getwd()
//   newModule(guestIO, defaultRootFS(), nil, dedupDirs(append(WritableDirs, cwd, os.TempDir())))
```

---

## Benefits

1. **Zero signature change.** No new exported functions or types. Consistent with `Arg1`/`Config`.

2. **Caller opt-in.** Default is nil — no behavioral change for callers who do not set it.

3. **ncruces compatibility.** `WritableDirs` does not exist on ncruces; callers targeting both
   backends set it conditionally on build tag or interface detection. Callers who only need
   CWD-relative writes (covered by default) need no change at all.

4. **Generalizable pattern.** Any Go module wrapping a WASI sandbox can adopt the same variable
   name and semantics. Callers who use multiple WASI-backed modules face a consistent interface.

---

## Applicability Beyond go-exiftool-wasm

This pattern is directly portable to any Go module that:
- Embeds a WASI guest via wasm2go or wazero
- Uses a mount table to mediate filesystem access
- Exposes a stable public API that cannot add function parameters

The variable name `WritableDirs`, declaration location (`init.go` or equivalent), and the
`dedupDirs` deduplication helper can be copied verbatim. The only host-specific part is where
`WritableDirs` is consumed — the `newModule` (or equivalent) call site.

---

## Implementation Cost

- `init.go`: 10 lines (var declaration + doc comment)
- `cmd.go`: 15 lines (`dedupDirs` helper + updated `newModule` call + doc comment update)
- `write_test.go`: ~35 lines (one test with `t.Cleanup` save/restore)
- `README.md`: ~10 lines ("Writing Files" section)
- `ARCHITECTURE.md`: 2–3 lines

Total: ~75 lines across 5 files.

---

## Test Pattern

```go
func TestWritableDirs_externalPath(t *testing.T) {
    targetDir := "/some/absolute/path"
    if err := os.MkdirAll(targetDir, 0o755); err != nil {
        t.Skip("cannot create target dir:", err)
    }

    orig := WritableDirs
    t.Cleanup(func() { WritableDirs = orig })
    WritableDirs = []string{targetDir}

    out, err := Command(nil, "-tagsFromFile", "src.jpg", "-overwrite_original",
        filepath.Join(targetDir, "dst.jpg"))
    if err != nil {
        t.Fatalf("Command: %v\noutput: %s", err, out)
    }
}
```

The `t.Cleanup` restore is mandatory — `WritableDirs` is package-level state and will leak into
parallel tests if not restored.

---

## Caveats

- **Race condition.** Setting a package-level variable before a call is not safe under
  `t.Parallel()` or concurrent callers. If per-call isolation is required, a context-value
  approach or a functional options API is safer. See the comment in the test pattern above.

- **Path validation.** The current `mountEntry` model does not validate that `hostRoot` is a
  real directory at mount time. Passing a non-existent path silently produces `ENOENT` for any
  guest write attempt rather than a clear error at setup time. A validation pass in `newModule`
  would improve debuggability.

- **Server mode.** `NewServer` creates one module instance reused across many `Server.Command`
  calls. `WritableDirs` set after `NewServer` returns would not affect an already-running server's
  mount table. The fix requires either re-reading `WritableDirs` per-command (not possible with
  the current server architecture) or documenting that `WritableDirs` must be set before
  `NewServer` is called.
